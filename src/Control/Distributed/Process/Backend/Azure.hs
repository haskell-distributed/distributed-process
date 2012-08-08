module Control.Distributed.Process.Backend.Azure 
  ( -- * Initialization
    Backend(..)
  , AzureParameters(..)
  , defaultAzureParameters
  , initializeBackend
    -- * Re-exports from Azure Service Management
  , CloudService(..)
  , VirtualMachine(..)
  , Azure.cloudServices
    -- * Remote and local processes
  , ProcessPair(..)
  , RemoteProcess
  , LocalProcess
  , localExpect
  , remoteSend
  , remoteThrow
  , remoteSend'
  , localSend
  ) where

import System.Environment (getEnv)
import System.FilePath ((</>), takeFileName)
import System.Environment.Executable (getExecutablePath)
import System.IO (stdout, hFlush)
import Data.Binary (encode, decode)
import Data.Digest.Pure.MD5 (md5, MD5Digest)
import qualified Data.ByteString as BSS 
  ( ByteString
  , length
  , concat
  , hPut
  )
import qualified Data.ByteString.Char8 as BSSC (pack)
import qualified Data.ByteString.Lazy as BSL 
  ( ByteString
  , readFile
  , length
  , fromChunks
  , toChunks
  , hPut
  )
import qualified Data.ByteString.Lazy.Char8 as BSLC (unpack)
import Data.Typeable (Typeable)
import Control.Applicative ((<$>))
import Control.Monad (void, unless)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask)
import Control.Exception (Exception, catches, Handler(Handler))
import Control.Monad.IO.Class (MonadIO, liftIO)

-- Azure
import Network.Azure.ServiceManagement 
  ( CloudService(..)
  , VirtualMachine(..)
  , Endpoint(..)
  , AzureSetup
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
  , Channel
  )
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( openChannelSession
  , channelExecute
  , writeChannel
  , readChannel
  , channelSendEOF
  )
import qualified Network.SSH.Client.LibSSH2.Errors as SSH
  ( ErrorCode
  , NULL_POINTER
  , getLastError
  )

-- CH
import Control.Distributed.Process (Process, Closure)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.Types 
  ( messageToPayload
  , createMessage
  )
import Network.Transport.Internal (encodeInt32, decodeInt32, prependLength)

-- | Azure backend
data Backend = Backend {
    -- | Find virtual machines
    findVMs :: IO [VirtualMachine]
    -- | Copy the executable to a virtual machine
  , copyToVM :: VirtualMachine -> IO () 
    -- | Check the MD5 hash of the remote executable
  , checkMD5 :: VirtualMachine -> IO Bool 
    -- | @runOnVM dict vm port p@ starts a CH node on port 'port' and runs 'p'
  , callOnVM :: forall a. 
                VirtualMachine 
             -> String 
             -> ProcessPair a
             -> IO a 
    -- | Create a new CH node and run the specified process in the background.
    -- The CH node will exit when the process exists.
  , spawnOnVM :: VirtualMachine 
              -> String 
              -> Closure (Backend -> Process ()) 
              -> IO ()
  } deriving (Typeable)

data AzureParameters = AzureParameters {
    azureSetup           :: AzureSetup
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
  home  <- getEnv "HOME"
  user  <- getEnv "USER"
  self  <- getExecutablePath
  setup <- Azure.azureSetup sid x509 pkey 
  return AzureParameters 
    { azureSetup         = setup 
    , azureSshUserName   = user
    , azureSshPublicKey  = home </> ".ssh" </> "id_rsa.pub"
    , azureSshPrivateKey = home </> ".ssh" </> "id_rsa"
    , azureSshPassphrase = ""
    , azureSshKnownHosts = home </> ".ssh" </> "known_hosts"
    , azureSshRemotePath = takeFileName self
    , azureSshLocalPath  = self
    }

-- | Initialize the backend
initializeBackend :: AzureParameters -- ^ Connection parameters
                  -> String          -- ^ Cloud service name
                  -> IO Backend
initializeBackend params cloudService = 
  return Backend {
      findVMs   = apiFindVMs params cloudService 
    , copyToVM  = apiCopyToVM params 
    , checkMD5  = apiCheckMD5 params
    , callOnVM  = apiCallOnVM params
    , spawnOnVM = apiSpawnOnVM params
    }

-- | Find virtual machines
apiFindVMs :: AzureParameters -> String -> IO [VirtualMachine]
apiFindVMs params cloudService = do
  css <- Azure.cloudServices (azureSetup params) 
  case filter ((== cloudService) . cloudServiceName) css of
    [cs] -> return $ cloudServiceVMs cs
    _    -> return []

-- | Start a CH node on the given virtual machine
apiCopyToVM :: AzureParameters -> VirtualMachine -> IO ()
apiCopyToVM params vm = 
  void . withSSH2 params vm $ \s -> catchSshError s $
    SSH.scpSendFile s 0o700 (azureSshLocalPath params) (azureSshRemotePath params)

-- | Call a process on a VM 
apiCallOnVM :: AzureParameters 
            -> VirtualMachine 
            -> String 
            -> ProcessPair a
            -> IO a
apiCallOnVM params vm port ppair =
    withSSH2 params vm $ \s -> do
      let exe = "PATH=. " ++ azureSshRemotePath params 
             ++ " onvm run "
             ++ " --host " ++ vmIpAddress vm 
             ++ " --port " ++ port
             ++ " 2>&1"
      (status, r) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
        SSH.channelExecute ch exe
        _ <- SSH.writeChannel ch (encodeInt32 (BSL.length rprocEnc))
        _ <- SSH.writeAllChannel ch rprocEnc 
        runLocalProcess (ppairLocal ppair) ch
      if status == 0 
        then return r 
        else error "callOnVM: Non-zero exit status" 
  where
    rprocEnc :: BSL.ByteString
    rprocEnc = encode (ppairRemote ppair) 

apiSpawnOnVM :: AzureParameters 
             -> VirtualMachine 
             -> String 
             -> Closure (Backend -> Process ()) 
             -> IO ()
apiSpawnOnVM params vm port proc = 
    withSSH2 params vm $ \s -> do
      let exe = "PATH=. " ++ azureSshRemotePath params 
             ++ " onvm run "
             ++ " --host " ++ vmIpAddress vm 
             ++ " --port " ++ port
             ++ " --background "
             ++ " 2>&1"
      (status, r) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
        SSH.channelExecute ch exe
        _ <- SSH.writeChannel ch (encodeInt32 (BSL.length procEnc))
        _ <- SSH.writeAllChannel ch procEnc 
        SSH.channelSendEOF ch
        SSH.readAllChannel ch
      unless (status == 0) $ error (BSLC.unpack r)
  where
    procEnc :: BSL.ByteString
    procEnc = encode proc

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

--------------------------------------------------------------------------------
-- Local and remote processes                                                 --
--------------------------------------------------------------------------------

data ProcessPair a = ProcessPair {
    ppairRemote :: RemoteProcess () 
  , ppairLocal  :: LocalProcess a
  }

type RemoteProcess a = Closure (Backend -> Process a)

newtype LocalProcess a = LocalProcess { unLocalProcess :: ReaderT SSH.Channel IO a } 
  deriving (Functor, Monad, MonadIO, MonadReader SSH.Channel)

runLocalProcess :: LocalProcess a -> SSH.Channel -> IO a
runLocalProcess = runReaderT . unLocalProcess

localExpect :: Serializable a => LocalProcess a
localExpect = LocalProcess $ do
  ch <- ask 
  liftIO $ do
    isE <- readIntChannel ch
    len <- readIntChannel ch 
    msg <- readSizeChannel ch len
    if isE /= 0
      then error (decode msg)
      else return (decode msg)

localSend :: Serializable a => a -> LocalProcess ()
localSend x = LocalProcess $ do
  ch <- ask
  liftIO $ mapM_ (SSH.writeChannel ch) 
         . prependLength
         . messageToPayload 
         . createMessage 
         $ x 

remoteSend :: Serializable a => a -> Process ()
remoteSend = liftIO . remoteSend' 0  

remoteThrow :: Exception e => e -> Process ()
remoteThrow = liftIO . remoteSend' 1 . show 

remoteSend' :: Serializable a => Int -> a -> IO ()
remoteSend' flags x = do
  let enc = encode x
  BSS.hPut stdout (encodeInt32 flags)
  BSS.hPut stdout (encodeInt32 (BSL.length enc))
  BSL.hPut stdout enc
  hFlush stdout

--------------------------------------------------------------------------------
-- SSH utilities                                                              --
--------------------------------------------------------------------------------

readSizeChannel :: SSH.Channel -> Int -> IO BSL.ByteString
readSizeChannel ch = go []
  where
    go :: [BSS.ByteString] -> Int -> IO BSL.ByteString
    go acc 0    = return (BSL.fromChunks $ reverse acc)
    go acc size = do
      bs <- SSH.readChannel ch (fromIntegral (0x400 `min` size))
      go (bs : acc) (size - BSS.length bs)

readIntChannel :: SSH.Channel -> IO Int
readIntChannel ch = 
  decodeInt32 . BSS.concat . BSL.toChunks <$> readSizeChannel ch 4
