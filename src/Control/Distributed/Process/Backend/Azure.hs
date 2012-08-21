module Control.Distributed.Process.Backend.Azure 
  ( -- * Initialization
    Backend(..)
  , AzureParameters(..)
  , defaultAzureParameters
  , initializeBackend
    -- * Re-exports from Azure Service Management
  , CloudService(..)
  , VirtualMachine(..)
  , Endpoint(..)
  , AzureSetup
  , Azure.cloudServices
    -- * Remote and local processes
  , ProcessPair(..)
  , RemoteProcess
  , LocalProcess
  , localSend
  , localExpect
  , remoteSend
  , remoteThrow
  ) where

import System.Environment (getEnv)
import System.FilePath ((</>), takeFileName)
import System.Environment.Executable (getExecutablePath)
import System.IO (stdout, hFlush)
import Data.Binary (Binary(get, put), encode, decode)
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
import Control.Applicative ((<$>), (<*>))
import Control.Monad (void, unless)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask)
import Control.Exception (Exception, catches, Handler(Handler), throwIO)
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
    -- | @runOnVM vm port pp@ starts a new CH node on machine @vm@ and then
    -- runs the specified process pair. The CH node will shut down when the
    -- /local/ process exists. @callOnVM@ returns the returned by the local
    -- process on exit.
  , callOnVM :: forall a. VirtualMachine -> String -> ProcessPair a -> IO a 
    -- | Create a new CH node and run the specified process.
    -- The CH node will shut down when the /remote/ process exists. @spawnOnVM@
    -- returns as soon as the process has been spawned.
  , spawnOnVM :: VirtualMachine -> String -> RemoteProcess () -> IO ()
  } deriving (Typeable)

-- | Azure connection parameters
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

instance Binary AzureParameters where
  put params = do
    put (azureSetup params)
    put (azureSshUserName params)
    put (azureSshPublicKey params)
    put (azureSshPrivateKey params)
    put (azureSshPassphrase params)
    put (azureSshKnownHosts params)
    put (azureSshRemotePath params)
    put (azureSshLocalPath params)
  get = 
    AzureParameters <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get

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
    , callOnVM  = apiCallOnVM params cloudService
    , spawnOnVM = apiSpawnOnVM params cloudService
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
            -> String
            -> VirtualMachine 
            -> String 
            -> ProcessPair a
            -> IO a
apiCallOnVM params cloudService vm port ppair =
    withSSH2 params vm $ \s -> do
      let exe = "PATH=. " ++ azureSshRemotePath params 
             ++ " onvm run "
             ++ " --host " ++ vmIpAddress vm 
             ++ " --port " ++ port
             ++ " --cloud-service " ++ cloudService 
             ++ " 2>&1"
      let paramsEnc = encode params
      (status, r) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
        SSH.channelExecute ch exe
        SSH.writeChannel ch (encodeInt32 (BSL.length rprocEnc))
        SSH.writeAllChannel ch rprocEnc 
        SSH.writeChannel ch (encodeInt32 (BSL.length paramsEnc))
        SSH.writeAllChannel ch paramsEnc 
        runLocalProcess (ppairLocal ppair) ch
      if status == 0 
        then return r 
        else error "callOnVM: Non-zero exit status" 
  where
    rprocEnc :: BSL.ByteString
    rprocEnc = encode (ppairRemote ppair) 

apiSpawnOnVM :: AzureParameters 
             -> String
             -> VirtualMachine 
             -> String 
             -> Closure (Backend -> Process ()) 
             -> IO ()
apiSpawnOnVM params cloudService vm port proc = 
    withSSH2 params vm $ \s -> do
      -- TODO: reduce duplication with apiCallOnVM
      let exe = "PATH=. " ++ azureSshRemotePath params 
             ++ " onvm run "
             ++ " --host " ++ vmIpAddress vm 
             ++ " --port " ++ port
             ++ " --cloud-service " ++ cloudService
             ++ " --background "
             ++ " 2>&1"
      let paramsEnc = encode params
      (status, r) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
        SSH.channelExecute ch exe
        SSH.writeChannel ch (encodeInt32 (BSL.length procEnc))
        SSH.writeAllChannel ch procEnc 
        SSH.writeChannel ch (encodeInt32 (BSL.length paramsEnc))
        SSH.writeAllChannel ch paramsEnc 
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

-- | A process pair consists of a remote process and a local process. The local
-- process can send messages to the remote process using 'localSend' and wait
-- for messages from the remote process using 'localExpect'. The remote process
-- can send messages to the local process using 'remoteSend', and wait for
-- messages from the local process using the standard Cloud Haskell primitives.
-- 
-- See also 'callOnVM'.
data ProcessPair a = ProcessPair {
    ppairRemote :: RemoteProcess () 
  , ppairLocal  :: LocalProcess a
  }

-- | The process to run on the remote node (see 'ProcessPair' and 'callOnVM').
type RemoteProcess a = Closure (Backend -> Process a)

-- | The process to run on the local node (see 'ProcessPair' and 'callOnVM').
newtype LocalProcess a = LocalProcess { unLocalProcess :: ReaderT SSH.Channel IO a } 
  deriving (Functor, Monad, MonadIO, MonadReader SSH.Channel)

runLocalProcess :: LocalProcess a -> SSH.Channel -> IO a
runLocalProcess = runReaderT . unLocalProcess

-- | Send a messages from the local process to the remote process 
-- (see 'ProcessPair')
localSend :: Serializable a => a -> LocalProcess ()
localSend x = LocalProcess $ do
  ch <- ask
  liftIO $ mapM_ (SSH.writeChannel ch) 
         . prependLength
         . messageToPayload 
         . createMessage 
         $ x 

-- | Wait for a message from the remote process (see 'ProcessPair').
-- Note that unlike for the standard Cloud Haskell 'expect' it will result in a
-- runtime error if the remote process sends a message of type other than @a@.
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

-- | Send a message from the remote process to the local process (see
-- 'ProcessPair'). Note that the remote process can use the standard Cloud
-- Haskell primitives to /receive/ messages from the local process.
remoteSend :: Serializable a => a -> Process ()
remoteSend = liftIO . remoteSend' 0  

-- | If the remote process encounters an error it can use 'remoteThrow'. This
-- will cause the exception to be raised (as a user-exception, not as the
-- original type) in the local process (as well as in the remote process).
remoteThrow :: Exception e => e -> IO ()
remoteThrow e = remoteSend' 1 (show e) >> throwIO e

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
