-- | This module provides the low-level API to running Cloud Haskell on
-- Microsoft Azure virtual machines (<http://www.windowsazure.com>). Virtual
-- machines within an Azure cloud service can talk to each other directly using
-- standard Cloud Haskell primitives (using TCP/IP under the hood); to talk to
-- the remote machines from your local machine you can use the primitives
-- provided in this module (which use ssh under the hood). It looks something
-- like 
--
-- >                _  _
-- >               ( `   )_
-- >              (    )    `)     Azure cloud service
-- >            (_   (_ .  _) _)
-- >  
-- >                   |
-- >                   | ssh connection
-- >                   |
-- > 
-- >                 +---+
-- >                 |   |   Local machine
-- >                 +---+
--
-- In this module we concentrate on the link between the local machine to the
-- remote machines. "Control.Distributed.Process.Backend.Azure.Process" provides
-- a higher-level interface that can be used in code that runs on the remote
-- machines.
--
-- /NOTE/: It is unfortunate that the local machine cannot talk to the remote
-- machine using the standard Cloud Haskell primitives. In an ideal world, we
-- could just start a Cloud Haskell node on the local machine, too.
-- Unfortunately, Cloud Haskell does not yet support using multiple network
-- transports (TCP/IP vs SSH). This is a temporary workaround.
--
-- [Azure Setup]
--
-- In this section we describe how to set up an Azure Cloud Service for use
-- with Cloud Haskell, starting from a brand new Azure account. It is not
-- intended as an Azure tutorial, but as a guide to making the right choices to
-- get Cloud Haskell up and running as quickly as possible.
--
-- An Azure /Cloud Service/ is a set of virtual machines that can talk to each
-- other directly over TCP/IP (they are part of the same private network). You
-- don't create the cloud service directly; instead, after you have set up your
-- first virtual machine as a /stand alone/ virtual machine, you can /connect/
-- subsequent virtual machines to the first virtual machine, thereby implicitly
-- setting up a Cloud Service.
--
-- We have only tested Cloud Haskell with Linux based virtual machines; 
-- Windows based virtual machines /might/ work, but you'll be entering
-- unchartered territory. Cloud Haskell assumes that all nodes run the same
-- binary code; hence, you must use the same OS on all virtual machines, 
-- /as well as on your local machine/. We use Ubuntu Server 12.04 LTS for our
-- tests (running on VirtualBox on our local machine). 
--
-- When you set up your virtual machine, you can pick an arbitrary name; these
-- names are for your own use only and do not need to be globally unique. Set a
-- username and password; you should use the same username on all virtual
-- machines. You should also upload
-- an SSH key for authentication (see 
-- /Converting OpenSSH keys for use on Windows Azure Linux VM's/,
-- <http://utlemming.azurewebsites.net/?p=91>, for
-- information on how to convert a standard Linux @id_rsa.pub@ public key to
-- X509 format suitable for Azure). For the first VM you create select
-- /Standalone Virtual Machine/, and pick an appropriate DNS name. The DNS name
-- /does/ have to be globally unique, and will also be the name of the Cloud
-- Service. For subsequent virtual machines, select 
-- /Connect to Existing Virtual Machine/ instead and then select the first VM
-- you created. 
--
-- In these notes, we assume three virtual machines called @CHDemo1@,
-- @CHDemo2@, and @CHDemo3@, all part of the @CloudHaskellDemo@ cloud service.
--
-- [Obtaining a Management Certificate]
--
-- Azure authentication is by means of an X509 certificate and corresponding
-- private key. /Create management certificates for Linux in Windows Azure/,
-- <https://www.windowsazure.com/en-us/manage/linux/common-tasks/manage-certificates/>,
-- describes how you can create a management certificate for Azure, download it
-- as a @.publishsettings@ file, and extract an @.pfx@ file from it. You cannot
-- use this @.pfx@ directly; instead, you will need to extract an X509
-- certificate from it and a private key in suitable format. You can use the
-- @openssl@ command line tool for both tasks; assuming that you stored the
-- @.pfx@ file as @credentials.pfx@, to extract the X509 certificate:
--
-- > openssl pkcs12 -in credentials.pfx -nokeys -out credentials.x509
--
-- And to extract the private key:
--
-- > openssl pkcs12 -in credentials.pfx -nocerts -nodes | openssl rsa -out credentials.private 
--
-- (@openssl pkcs12@ outputs the private key in PKCS#8 format (BEGIN PRIVATE
-- KEY), but we need it in PKCS#1 format (BEGIN RSA PRIVATE KEY).
--  
-- [Testing the Setup]
--
-- Build and install the @distributed-process-azure@ package, making sure to
-- pass the @build-demos@ flag to Cabal.
-- 
-- > cabal-dev install distributed-process-azure -f build-demos
--
-- We can use any of the demos to test our setup; we will use the @ping@ demo:
-- 
-- > cloud-haskell-azure-ping list \
-- >   --subscription-id <<your subscription ID>> \
-- >   --certificate /path/to/credentials.x509 \
-- >   --private /path/to/credentials.private
-- 
-- (you can find your subscription ID in the @.publishsettings@ file from the previous step).
-- If everything went well, this will output something like
--
-- > Cloud Service "CloudHaskellDemo"
-- >   VIRTUAL MACHINES
-- >     Virtual Machine "CHDemo3"
-- >       IP 10.119.182.127
-- >       INPUT ENDPOINTS
-- >         Input endpoint "SSH"
-- >           Port 50136
-- >           VIP 168.63.31.38
-- >     Virtual Machine "CHDemo2"
-- >       IP 10.59.238.125
-- >       INPUT ENDPOINTS
-- >         Input endpoint "SSH"
-- >           Port 63365
-- >           VIP 168.63.31.38
-- >     Virtual Machine "CHDemo1"
-- >       IP 10.59.224.122
-- >       INPUT ENDPOINTS
-- >         Input endpoint "SSH"
-- >           Port 22
-- >           VIP 168.63.31.38
--
-- The IP addresses listed are /internal/ IP addresses; they can be used by the
-- virtual machines to talk to each other, but not by the outside world to talk
-- to the virtual machines. To do that, you will need to use the VIP (Virtual
-- IP) address instead, which you will notice is the same for all virtual
-- machines that are part of the cloud service. The corresponding DNS name
-- (here @CloudHaskellDemo.cloudapp.net@) will also resolve to this (V)IP
-- address. To login to individual machines (through SSH) you will need to use
-- the specific port mentioned under INPUT ENDPOINTS.
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
