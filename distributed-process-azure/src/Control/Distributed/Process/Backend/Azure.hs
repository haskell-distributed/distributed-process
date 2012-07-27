module Control.Distributed.Process.Backend.Azure 
  ( -- * Initialization
    Backend(..)
  , AzureParameters(..)
  , defaultAzureParameters
  , initializeBackend
    -- * Re-exports from Azure Service Management
  , VirtualMachine(..)
  ) where

import System.Environment (getEnv)
import System.FilePath ((</>))
import Network.Azure.ServiceManagement 
  ( VirtualMachine 
  , virtualMachines
  , azureSetup
  )

-- | Azure backend
data Backend = Backend {
    findVMs :: IO [VirtualMachine]
  }

data AzureParameters = AzureParameters {
    azureSubscriptionId  :: String 
  , azureAuthCertificate :: FilePath 
  , azureAuthPrivateKey  :: FilePath 
  , azureSshPublicKey    :: FilePath
  , azureSshPrivateKey   :: FilePath
  , azureSshKnownHosts   :: FilePath
  }

-- | Create default azure parameters
defaultAzureParameters :: String  -- ^ Azure subscription ID
                       -> FilePath  -- ^ Path to X509 certificate
                       -> FilePath  -- ^ Path to private key
                       -> IO AzureParameters
defaultAzureParameters sid x509 pkey = do
  home <- getEnv "HOME"
  return AzureParameters 
    { azureSubscriptionId  = sid
    , azureAuthCertificate = x509
    , azureAuthPrivateKey  = pkey
    , azureSshPublicKey    = home </> ".ssh" </> "id_rsa.pub"
    , azureSshPrivateKey   = home </> ".ssh" </> "id_rsa"
    , azureSshKnownHosts   = home </> ".ssh" </> "known_hosts"
    }

-- | Initialize the backend
initializeBackend :: AzureParameters -> IO Backend
initializeBackend params = do
  setup <- azureSetup (azureSubscriptionId params)
                      (azureAuthCertificate params)
                      (azureAuthPrivateKey params)
  return Backend {
      findVMs = virtualMachines setup
    }
   
