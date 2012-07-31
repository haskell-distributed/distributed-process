module Control.Distributed.Process.Backend.Azure 
  ( -- * Initialization
    Backend(..)
  , AzureParameters(..)
  , defaultAzureParameters
  , initializeBackend
    -- * Re-exports from Azure Service Management
  , CloudService(..)
  , VirtualMachine(..)
  ) where

import System.Environment (getEnv)
import System.FilePath ((</>), takeFileName)
import System.Environment.Executable (getExecutablePath)
import Data.Digest.Pure.MD5 (md5, MD5Digest)
import qualified Data.ByteString.Lazy as BSL (readFile)
import Control.Applicative ((<$>))
import Network.Azure.ServiceManagement 
  ( CloudService(..)
  , VirtualMachine(..)
  , Endpoint(..)
  )
import qualified Network.Azure.ServiceManagement as Azure
  ( cloudServices 
  , azureSetup
  , vmSshEndpoint
  ) 
import qualified Network.SSH.Client.LibSSH2 as SSH
  ( withSSH2
  , execCommands
  , scpSendFile
  , withChannel
  , readAllChannel
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( openChannelSession
  , retryIfNeeded
  , channelExecute
  , writeChannel
  , channelSendEOF
  )

-- | Azure backend
data Backend = Backend {
    -- | Find virtual machines
    cloudServices :: IO [CloudService]
  , copyToVM     :: VirtualMachine -> IO () 
  , checkMD5      :: VirtualMachine -> IO Bool 
  }

data AzureParameters = AzureParameters {
    azureSubscriptionId  :: String 
  , azureAuthCertificate :: FilePath 
  , azureAuthPrivateKey  :: FilePath 
  , azureSshUserName     :: FilePath
  , azureSshPublicKey    :: FilePath
  , azureSshPrivateKey   :: FilePath
  , azureSshPassphrase   :: String
  , azureSshKnownHosts   :: FilePath
  , azureSshRemotePath   :: FilePath
  , azureSshLocalPath    :: FilePath
  }

-- | Create default azure parameters
defaultAzureParameters :: String    -- ^ Azure subscription ID
                       -> FilePath  -- ^ Path to X509 certificate
                       -> FilePath  -- ^ Path to private key
                       -> IO AzureParameters
defaultAzureParameters sid x509 pkey = do
  home <- getEnv "HOME"
  user <- getEnv "USER"
  self <- getExecutablePath
  return AzureParameters 
    { azureSubscriptionId  = sid
    , azureAuthCertificate = x509
    , azureAuthPrivateKey  = pkey
    , azureSshUserName     = user
    , azureSshPublicKey    = home </> ".ssh" </> "id_rsa.pub"
    , azureSshPrivateKey   = home </> ".ssh" </> "id_rsa"
    , azureSshPassphrase   = ""
    , azureSshKnownHosts   = home </> ".ssh" </> "known_hosts"
    , azureSshRemotePath   = takeFileName self
    , azureSshLocalPath    = self
    }

-- | Initialize the backend
initializeBackend :: AzureParameters -> IO Backend
initializeBackend params = do
  setup <- Azure.azureSetup (azureSubscriptionId params)
                            (azureAuthCertificate params)
                            (azureAuthPrivateKey params)
  return Backend {
      cloudServices = Azure.cloudServices setup
    , copyToVM     = apiCopyToVM params 
    , checkMD5      = apiCheckMD5 params
    }

-- | Start a CH node on the given virtual machine
apiCopyToVM :: AzureParameters -> VirtualMachine -> IO ()
apiCopyToVM params (Azure.vmSshEndpoint -> Just ep) = do
  _ <- SSH.withSSH2 (azureSshKnownHosts params)
                    (azureSshPublicKey params)
                    (azureSshPrivateKey params)
                    (azureSshPassphrase params)
                    (azureSshUserName params)
                    (endpointVip ep)
                    (read $ endpointPort ep) $ \fd s -> do
      SSH.scpSendFile fd s 0o700 (azureSshLocalPath params) (azureSshRemotePath params)
      -- SSH.execCommands fd s ["nohup /home/edsko/testservice >/dev/null 2>&1 &"]
  return ()
apiCopyToVM _ _ = 
  error "copyToVM: No SSH endpoint"

apiCheckMD5 :: AzureParameters -> VirtualMachine -> IO Bool 
apiCheckMD5 params (Azure.vmSshEndpoint -> Just ep) = do
  hash <- localHash params
  match <- SSH.withSSH2 (azureSshKnownHosts params)
                        (azureSshPublicKey params)
                        (azureSshPrivateKey params)
                        (azureSshPassphrase params)
                        (azureSshUserName params)
                        (endpointVip ep)
                        (read $ endpointPort ep) $ \fd s -> do
    (r, _) <- SSH.withChannel (SSH.openChannelSession s) id fd s $ \ch -> do
      SSH.retryIfNeeded fd s $ SSH.channelExecute ch ("md5sum -c --status")
      SSH.writeChannel ch $ show hash ++ "  " ++ azureSshRemotePath params 
      SSH.channelSendEOF ch
      SSH.readAllChannel fd ch
    return (r == 0)
  return match
apiCheckMD5 _ _ = 
  error "checkMD5: No SSH endpoint"

localHash :: AzureParameters -> IO MD5Digest 
localHash params = md5 <$> BSL.readFile (azureSshLocalPath params) 
