{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Backend.Azure 
  ( -- * Initialization
    Backend(..)
  , AzureParameters(..)
  , defaultAzureParameters
  , initializeBackend
  , remoteTable
    -- * Re-exports from Azure Service Management
  , CloudService(..)
  , VirtualMachine(..)
  ) where

import System.Environment (getEnv)
import System.FilePath ((</>), takeFileName)
import System.Environment.Executable (getExecutablePath)
import Data.Binary (encode, decode)
import Data.Digest.Pure.MD5 (md5, MD5Digest)
import qualified Data.ByteString.Char8 as BSSC (pack)
import qualified Data.ByteString.Lazy as BSL (ByteString, readFile, putStr)
import Data.Typeable (Typeable)
import Control.Applicative ((<$>))
import Control.Monad (void)
import Control.Exception (catches, Handler(Handler))
import Control.Monad.IO.Class (liftIO)

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
  , withChannelBy
  , Session
  , readAllChannel
  , writeAllChannel
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( openChannelSession
  , channelExecute
  , writeChannel
  , channelSendEOF
  )
import qualified Network.SSH.Client.LibSSH2.Errors as SSH
  ( ErrorCode
  , NULL_POINTER
  , getLastError
  )

-- CH
import Control.Distributed.Process 
  ( Closure(Closure)
  , Process
  , Static
  , RemoteTable
  )
import Control.Distributed.Process.Closure 
  ( remotable
  , cpBind
  , SerializableDict(SerializableDict)
  , staticConst
  , staticApply
  , mkStatic
  )
import Control.Distributed.Process.Serializable (Serializable)

encodeToStdout :: Serializable a => a -> Process ()
encodeToStdout = liftIO . BSL.putStr . encode

encodeToStdoutDict :: SerializableDict a -> a -> Process ()
encodeToStdoutDict SerializableDict = encodeToStdout

remotable ['encodeToStdoutDict]

-- | Remote table necessary for the Azure backend
remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

cpEncodeToStdout :: forall a. Typeable a => Static (SerializableDict a) -> Closure (a -> Process ())
cpEncodeToStdout dict = Closure decoder (encode ())
  where
    decoder :: Static (BSL.ByteString -> a -> Process ())
    decoder = staticConst `staticApply` ($(mkStatic 'encodeToStdoutDict) `staticApply` dict)

-- | Azure backend
data Backend = Backend {
    -- | Find virtual machines
    cloudServices :: IO [CloudService]
    -- | Copy the executable to a virtual machine
  , copyToVM :: VirtualMachine -> IO () 
    -- | Check the MD5 hash of the remote executable
  , checkMD5 :: VirtualMachine -> IO Bool 
    -- | @runOnVM dict vm port p@ starts a CH node on port 'port' and runs 'p'
  , callOnVM :: forall a. Serializable a => Static (SerializableDict a) -> VirtualMachine -> String -> Closure (Process a) -> IO a 
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
    , callOnVM      = apiCallOnVM params
    }

-- | Start a CH node on the given virtual machine
apiCopyToVM :: AzureParameters -> VirtualMachine -> IO ()
apiCopyToVM params vm = 
  void . withSSH2 params vm $ \s -> catchSshError s $
    SSH.scpSendFile s 0o700 (azureSshLocalPath params) (azureSshRemotePath params)

-- | Call a process on a VM 
apiCallOnVM :: Serializable a => AzureParameters -> Static (SerializableDict a) -> VirtualMachine -> String -> Closure (Process a) -> IO a
apiCallOnVM params dict vm port proc =
    withSSH2 params vm $ \s -> do
      let exe = "PATH=. " ++ azureSshRemotePath params 
             ++ " onvm run "
             ++ " --host " ++ vmIpAddress vm 
             ++ " --port " ++ port
             ++ " 2>&1"
      (_, r) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
        SSH.channelExecute ch exe
        _cnt <- SSH.writeAllChannel ch (encode proc') 
        SSH.channelSendEOF ch
        SSH.readAllChannel ch
      return (decode r)
  where
    proc' :: Closure (Process ())
    proc' = proc `cpBind` cpEncodeToStdout dict   

-- | Check the MD5 hash of the executable on the remote machine
apiCheckMD5 :: AzureParameters -> VirtualMachine -> IO Bool 
apiCheckMD5 params vm = do
  hash <- localHash params
  withSSH2 params vm $ \s -> do
    (r, _) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
      SSH.channelExecute ch "md5sum -c --status"
      SSH.writeChannel ch . BSSC.pack $ show hash ++ "  " ++ azureSshRemotePath params 
      SSH.channelSendEOF ch
      SSH.readAllChannel ch
    return (r == 0)

withSSH2 :: AzureParameters -> VirtualMachine -> (SSH.Session -> IO a) -> IO a 
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
