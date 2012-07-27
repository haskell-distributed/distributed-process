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
import System.FilePath ((</>))
import System.Environment.Executable (getExecutablePath)
import Control.Concurrent (threadDelay)
import Network.Azure.ServiceManagement 
  ( CloudService(..)
  , VirtualMachine(..)
  , Endpoint(..)
  )
import qualified Network.Azure.ServiceManagement as Azure
  ( cloudServices 
  , AzureSetup
  , azureSetup
  , vmSshEndpoint
  ) 
import qualified Network.SSH.Client.LibSSH2 as SSH
  ( withSSH2
  , retryIfNeeded
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( initialize 
  , exit
  , channelExecute
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
  , azureSshKnownHosts   :: FilePath
  }

-- | Create default azure parameters
defaultAzureParameters :: String    -- ^ Azure subscription ID
                       -> FilePath  -- ^ Path to X509 certificate
                       -> FilePath  -- ^ Path to private key
                       -> IO AzureParameters
defaultAzureParameters sid x509 pkey = do
  home <- getEnv "HOME"
  user <- getEnv "USER"
  return AzureParameters 
    { azureSubscriptionId  = sid
    , azureAuthCertificate = x509
    , azureAuthPrivateKey  = pkey
    , azureSshUserName     = user
    , azureSshPublicKey    = home </> ".ssh" </> "id_rsa.pub"
    , azureSshPrivateKey   = home </> ".ssh" </> "id_rsa"
    , azureSshKnownHosts   = home </> ".ssh" </> "known_hosts"
    }

-- | Initialize the backend
initializeBackend :: AzureParameters -> IO Backend
initializeBackend params = do
  setup <- Azure.azureSetup (azureSubscriptionId params)
                            (azureAuthCertificate params)
                            (azureAuthPrivateKey params)
  exe <- getExecutablePath
  print exe
  return Backend {
      cloudServices = Azure.cloudServices setup
    , startOnVM     = apiStartOnVM params 
    }

-- | Start a CH node on the given virtual machine
apiStartOnVM :: AzureParameters -> VirtualMachine -> IO ()
apiStartOnVM params vm = do
  _ <- SSH.initialize True
  let ep = Azure.vmSshEndpoint vm
  SSH.withSSH2 (azureSshKnownHosts params)
               (azureSshPublicKey params)
               (azureSshPrivateKey params)
               (azureSshUserName params)
               (endpointVip ep)
               (read $ endpointPort ep) $ \fd s ch -> do
      _ <- SSH.retryIfNeeded fd s $ SSH.channelExecute ch "/home/edsko/testservice"
      threadDelay $ 10 * 1000000 -- 10 seconds
      return ()
  SSH.exit
