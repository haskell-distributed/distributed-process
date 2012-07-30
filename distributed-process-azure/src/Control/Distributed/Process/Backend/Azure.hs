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
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( initialize 
  , exit
  )

-- | Azure backend
data Backend = Backend {
    -- | Find virtual machines
    cloudServices :: IO [CloudService]
  , startOnVM     :: VirtualMachine -> IO () 
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
    , azureSshRemotePath   = "/home" </> user </> takeFileName self
    }

-- | Initialize the backend
initializeBackend :: AzureParameters -> IO Backend
initializeBackend params = do
  setup <- Azure.azureSetup (azureSubscriptionId params)
                            (azureAuthCertificate params)
                            (azureAuthPrivateKey params)
  return Backend {
      cloudServices = Azure.cloudServices setup
    , startOnVM     = apiStartOnVM params 
    }

-- | Start a CH node on the given virtual machine
apiStartOnVM :: AzureParameters -> VirtualMachine -> IO ()
apiStartOnVM params (Azure.vmSshEndpoint -> Just ep) = do
  _ <- SSH.initialize True
  _ <- SSH.withSSH2 (azureSshKnownHosts params)
                    (azureSshPublicKey params)
                    (azureSshPrivateKey params)
                    (azureSshPassphrase params)
                    (azureSshUserName params)
                    (endpointVip ep)
                    (read $ endpointPort ep) $ \fd s -> do
      SSH.execCommands fd s ["nohup /home/edsko/testservice >/dev/null 2>&1 &"]
  SSH.exit
apiStartOnVM _ _ = 
  error "startOnVM: No SSH endpoint"
