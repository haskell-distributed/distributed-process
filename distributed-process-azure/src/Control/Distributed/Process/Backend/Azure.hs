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
import System.Posix.Types (Fd)
import Data.Binary (encode)
import Data.Digest.Pure.MD5 (md5, MD5Digest)
import qualified Data.ByteString.Lazy as BSL (readFile)
import qualified Data.ByteString.Lazy.Char8 as BSLC (putStr)
import Control.Applicative ((<$>))
import Control.Monad (void)
import Control.Exception (catches, Handler(Handler))

-- Azure
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

-- SSH
import qualified Network.SSH.Client.LibSSH2 as SSH
  ( withSSH2
  , scpSendFile
  , withChannel
  , Session
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( openChannelSession
  , retryIfNeeded
  , channelExecute
  , writeChannel
  , channelSendEOF
  )
import qualified Network.SSH.Client.LibSSH2.Errors as SSH
  ( ErrorCode
  , NULL_POINTER
  , getLastError
  )
import qualified Network.SSH.Client.LibSSH2.ByteString.Lazy as SSHBS
  ( writeChannel
  , readAllChannel
  )

-- CH
import Control.Distributed.Process 
  ( Closure
  , Process
  )

-- | Azure backend
data Backend = Backend {
    -- | Find virtual machines
    cloudServices :: IO [CloudService]
    -- | Copy the executable to a virtual machine
  , copyToVM :: VirtualMachine -> IO () 
    -- | Check the MD5 hash of the remote executable
  , checkMD5 :: VirtualMachine -> IO Bool 
    -- | @runOnVM vm port p@ starts a CH node on port 'port' and runs 'p'
  , runOnVM :: VirtualMachine -> String -> Closure (Process ()) -> IO ()
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
    , copyToVM      = apiCopyToVM params 
    , checkMD5      = apiCheckMD5 params
    , runOnVM       = apiRunOnVM params
    }

-- | Start a CH node on the given virtual machine
apiCopyToVM :: AzureParameters -> VirtualMachine -> IO ()
apiCopyToVM params vm = 
  void . withSSH2 params vm $ \fd s -> catchSshError s $
    SSH.scpSendFile fd s 0o700 (azureSshLocalPath params) (azureSshRemotePath params)

-- | Start the executable on the remote machine
apiRunOnVM :: AzureParameters -> VirtualMachine -> String -> Closure (Process ()) -> IO ()
apiRunOnVM params vm port proc =
  void . withSSH2 params vm $ \fd s -> do
    let exe = "PATH=. " ++ azureSshRemotePath params 
           ++ " onvm run "
           ++ " --host " ++ vmIpAddress vm 
           ++ " --port " ++ port
           ++ " 2>&1"
    (_, r) <- SSH.withChannel (SSH.openChannelSession s) id fd s $ \ch -> do
      SSH.retryIfNeeded fd s $ SSH.channelExecute ch exe
      SSHBS.writeChannel fd ch (encode proc) 
      SSH.channelSendEOF ch
      SSHBS.readAllChannel fd ch
    BSLC.putStr r

-- | Check the MD5 hash of the executable on the remote machine
apiCheckMD5 :: AzureParameters -> VirtualMachine -> IO Bool 
apiCheckMD5 params vm = do
  hash <- localHash params
  withSSH2 params vm $ \fd s -> do
    (r, _) <- SSH.withChannel (SSH.openChannelSession s) id fd s $ \ch -> do
      SSH.retryIfNeeded fd s $ SSH.channelExecute ch "md5sum -c --status"
      SSH.writeChannel ch $ show hash ++ "  " ++ azureSshRemotePath params 
      SSH.channelSendEOF ch
      SSHBS.readAllChannel fd ch
    return (r == 0)

withSSH2 :: AzureParameters -> VirtualMachine -> (Fd -> SSH.Session -> IO a) -> IO a 
withSSH2 params (Azure.vmSshEndpoint -> Just ep) = 
  SSH.withSSH2 (azureSshKnownHosts params)
               (azureSshPublicKey params)
               (azureSshPrivateKey params)
               (azureSshPassphrase params)
               (azureSshUserName params)
               (endpointVip ep)
               (read $ endpointPort ep)
withSSH2 _ vm = 
  error $ "withSSH2: No SSH endpoint for virtual machine " ++ vmName vm

catchSshError :: SSH.Session -> IO a -> IO a
catchSshError s io = 
    catches io [ Handler handleErrorCode
               , Handler handleNullPointer
               ]
  where
    handleErrorCode :: SSH.ErrorCode -> IO a
    handleErrorCode _ = do
      (_, str) <- SSH.getLastError s
      error str

    handleNullPointer :: SSH.NULL_POINTER -> IO a
    handleNullPointer _ = do 
      (_, str) <- SSH.getLastError s
      error str
  
localHash :: AzureParameters -> IO MD5Digest 
localHash params = md5 <$> BSL.readFile (azureSshLocalPath params) 
