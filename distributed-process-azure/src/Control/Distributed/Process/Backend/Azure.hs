-- | This module provides the API for running Cloud Haskell on Microsoft Azure
-- virtual machines (<http://www.windowsazure.com>). Virtual machines within an
-- Azure cloud service can talk to each other directly using standard Cloud
-- Haskell primitives (using TCP/IP under the hood); to talk to the remote
-- machines from your local machine you can use the primitives provided in this
-- module (which use ssh under the hood). It looks something like 
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
-- /NOTE/: It is unfortunate that the local machine cannot talk to the remote
-- machine using the standard Cloud Haskell primitives. In an ideal world, we
-- could just start a Cloud Haskell node on the local machine, too.
-- Unfortunately, Cloud Haskell does not yet support using multiple network
-- transports within the same system (i.e. both TCP/IP and SSH). This is a
-- temporary workaround.
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
-- When you set up your virtual machine, you can pick an arbitrary virtual
-- machine name; these names are for your own use only and do not need to be
-- globally unique. Set a username and password; you should use the same
-- username on all virtual machines. You should also upload an SSH key for
-- authentication (see 
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
-- Once your virtual machines have been set up, you have to make sure that the
-- user you created when you created the VM can ssh from any virtual machine to
-- any other using public key authentication. Moreover, you have to make sure
-- that @libssh2@ is installed; if you are using the Ubuntu image you can
-- install @libssh2@ using
--
-- > sudo apt-get install libssh2-1
--
-- (TODO: if you don't install libssh2 things will break without a clear error
-- message.)
--
-- In these notes, we assume three virtual machines called @CHDemo1@,
-- @CHDemo2@, and @CHDemo3@, all part of a @CloudHaskellDemo@ cloud service.
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
-- We can the @cloud-haskell-azure-ping@ demo to test our setup:
-- 
-- > cloud-haskell-azure-ping list \
-- >   <<your subscription ID>> \
-- >   /path/to/credentials.x509 \
-- >   /path/to/credentials.private 
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
--
-- [Overview of the API]
--
-- The Azure 'Backend' provides low-level functionality for interacting with
-- Azure virtual machines. 'findVMs' finds all currently available virtual
-- machines; 'copyToVM' copies the executable to a specified VM (recall that
-- all VMs, as well as the local machine, are assumed to run the same OS so
-- that they can all run the same binary), and 'checkMD5' checks the MD5 hash
-- of the executable on a remote machine.
--
-- 'callOnVM' and 'spawnOnVM' deal with setting up Cloud Haskell nodes.
-- 'spawnOnVM' takes a virtual machine and a port number, as well as a
-- @RemoteProcess ()@, starts the executable on the remote node, sets up a new
-- Cloud Haskell node, and then runs the specified process. The Cloud Haskell
-- node will be shut down when the given process terminates. 'RemoteProcess' is
-- defined as 
--
-- > type RemoteProcess a = Closure (Backend -> Process a)
--
-- (If you don't know what a 'Closure' is you should read
-- "Control.Distributed.Process.Closure".); the remote process will be supplied
-- with an Azure backend initialized with the same parameters. 'spawnOnVM'
-- returns once the Cloud Haskell node has been set up.
--
-- 'callOnVM' is similar to 'spawnOnVM', but it takes a /pair/ of processes:
-- one to run on the remote host (on a newly created Cloud Haskell node), and
-- one to run on the local machine. In this case, the new Cloud Haskell node
-- will be terminated when the /local/ process terminates. 'callOnVM' is useful
-- because the remote process and the local process can communicate through a
-- set of primitives provided in this module ('localSend', 'localExpect', and
-- 'remoteSend' -- there is no 'remoteExpect'; instead the remote process can
-- use the standard Cloud Haskell 'expect' primitive). 
--
-- [First Example: Echo]
--
-- When we run the @cloud-haskell-azure-echo@ demo on our local machine, it
-- starts a new Cloud Haskell node on the specified remote virtual machine. It
-- then repeatedly waits for input from the user on the local machine, sends
-- this to the remote virtual machine which will echo it back, and wait for and
-- show the echo. 
--
-- Before you can try it you will first need to copy the executable (for
-- example, using scp, although the Azure backend also provides this natively
-- in Haskell). Once that's done, you can run the demo as follows:
--
-- > cloud-haskell-azure-echo \ 
-- >   <<subscription ID>> \ 
-- >   /path/to/credentials.x509 \ 
-- >   /path/to/credentials.private \ 
-- >   <<remote username>> \ 
-- >   <<cloud service name>> \ 
-- >   <<virtual machine name>> \ 
-- >   <<port number>> 
-- > # Everything I type gets echoed back
-- > Echo: Everything I type gets echoed back
-- > # Until I enter a blank line
-- > Echo: Until I enter a blank line
-- > # 
--
-- The full @echo@ demo is
--
-- > {-# LANGUAGE TemplateHaskell #-}
-- > 
-- > import System.IO (hFlush, stdout)
-- > import System.Environment (getArgs)
-- > import Control.Monad (unless, forever)
-- > import Control.Monad.IO.Class (liftIO)
-- > import Control.Distributed.Process (Process, expect)
-- > import Control.Distributed.Process.Closure (remotable, mkClosure) 
-- > import Control.Distributed.Process.Backend.Azure 
-- > 
-- > echoRemote :: () -> Backend -> Process ()
-- > echoRemote () _backend = forever $ do
-- >   str <- expect 
-- >   remoteSend (str :: String)
-- > 
-- > remotable ['echoRemote]
-- > 
-- > echoLocal :: LocalProcess ()
-- > echoLocal = do
-- >   str <- liftIO $ putStr "# " >> hFlush stdout >> getLine
-- >   unless (null str) $ do
-- >     localSend str
-- >     liftIO $ putStr "Echo: " >> hFlush stdout
-- >     echo <- localExpect
-- >     liftIO $ putStrLn echo
-- >     echoLocal
-- > 
-- > main :: IO ()
-- > main = do
-- >   args <- getArgs
-- >   case args of
-- >     "onvm":args' -> 
-- >       -- Pass execution to 'onVmMain' if we are running on the VM
-- >       -- ('callOnVM' will provide the right arguments)
-- >       onVmMain __remoteTable args'
-- >
-- >     sid:x509:pkey:user:cloudService:virtualMachine:port:_ -> do
-- >       -- Initialize the Azure backend
-- >       params <- defaultAzureParameters sid x509 pkey 
-- >       let params' = params { azureSshUserName = user }
-- >       backend <- initializeBackend params' cloudService
-- >
-- >       -- Find the specified virtual machine
-- >       Just vm <- findNamedVM backend virtualMachine
-- >
-- >       -- Run the echo client proper 
-- >       callOnVM backend vm port $
-- >         ProcessPair ($(mkClosure 'echoRemote) ()) 
-- >                     echoLocal 
-- 
-- The most important part of this code is the last three lines
--
-- >       callOnVM backend vm port $
-- >         ProcessPair ($(mkClosure 'echoRemote) ()) 
-- >                     echoLocal 
--
-- 'callOnVM' creats a new Cloud Haskell node on the specified virtual machine,
-- then runs @echoRemote@ on the remote machine and @echoLocal@ on the local
-- machine.
--
-- [Second Example: Ping]
--
-- The second example differs from the @echo@ demo in that it uses both
-- 'callOnVM' and 'spawnOnVM'. It uses the latter to
-- install a ping server which keeps running in the background; it uses the
-- former to run a ping client which sends a request to the ping server and
-- outputs the response. 
--
-- As with the @echo@ demo, make sure to copy the executable to the remote server first.
-- Once that is done, you can start a ping server on a virtual machine using
--
-- > cloud-haskell-azure-ping server \
-- >   <<subscription ID>> \ 
-- >   /path/to/credentials.x509 \ 
-- >   /path/to/credentials.private \ 
-- >   <<remote username>> \
-- >   <<cloud service name>> \ 
-- >   <<virtual machine name>> \ 
-- >   <<port number>> 
--
-- As before, when we execute this on our local machine, it starts a new Cloud
-- Haskell node on the specified remote virtual machine and then executes the
-- ping server. Unlike with the echo example, however, this command will
-- terminate once the Cloud Haskell node has been set up, leaving the ping
-- server running in the background.
--
-- Once the ping server is running we can run the ping client:
--
-- > cloud-haskell-azure-ping client \
-- >   <<subscription ID>> \
-- >   /path/to/credentials.x509 \
-- >   /path/to/credentials.private \ 
-- >   <<remote username>> \
-- >   <<cloud service name>> \ 
-- >   <<virtual machine name>> \ 
-- >   <<DIFFERENT port number>> 
-- > Ping server at pid://10.59.224.122:8080:0:2 ok
--
-- Note that we must pass a different port number, because the client will run
-- within its own Cloud Haskell instance.
--
-- The code for the @ping@ demo is similar to the @echo@ demo, but uses both
-- 'callOnVM' and 'spawnOnVM' and demonstrates a way to discover processes (in
-- this case, through a PID file).
--
-- > {-# LANGUAGE TemplateHaskell #-}
-- > 
-- > import System.Environment (getArgs)
-- > import Data.Binary (encode, decode)
-- > import Control.Monad (forever)
-- > import Control.Monad.IO.Class (liftIO)
-- > import Control.Exception (try, IOException)
-- > import Control.Distributed.Process 
-- >   ( Process
-- >   , getSelfPid
-- >   , expect
-- >   , send
-- >   , monitor
-- >   , receiveWait
-- >   , match
-- >   , ProcessMonitorNotification(..)
-- >   )
-- > import Control.Distributed.Process.Closure (remotable, mkClosure) 
-- > import Control.Distributed.Process.Backend.Azure 
-- > import qualified Data.ByteString.Lazy as BSL (readFile, writeFile) 
-- > 
-- > pingServer :: () -> Backend -> Process ()
-- > pingServer () _backend = do
-- >   us <- getSelfPid
-- >   liftIO $ BSL.writeFile "pingServer.pid" (encode us)
-- >   forever $ do 
-- >     them <- expect
-- >     send them ()
-- > 
-- > pingClientRemote :: () -> Backend -> Process () 
-- > pingClientRemote () _backend = do
-- >   mPingServerEnc <- liftIO $ try (BSL.readFile "pingServer.pid")
-- >   case mPingServerEnc of
-- >     Left err -> 
-- >       remoteSend $ "Ping server not found: " ++ show (err :: IOException)
-- >     Right pingServerEnc -> do 
-- >       let pingServerPid = decode pingServerEnc
-- >       pid <- getSelfPid
-- >       _ref <- monitor pingServerPid 
-- >       send pingServerPid pid
-- >       gotReply <- receiveWait 
-- >         [ match (\() -> return True)
-- >         , match (\(ProcessMonitorNotification {}) -> return False)
-- >         ]
-- >       if gotReply
-- >         then remoteSend $ "Ping server at " ++ show pingServerPid ++ " ok"
-- >         else remoteSend $ "Ping server at " ++ show pingServerPid ++ " failure"
-- > 
-- > remotable ['pingClientRemote, 'pingServer]
-- > 
-- > pingClientLocal :: LocalProcess ()
-- > pingClientLocal = localExpect >>= liftIO . putStrLn 
-- > 
-- > main :: IO ()
-- > main = do
-- >   args <- getArgs
-- >   case args of
-- >     "onvm":args' -> 
-- >       -- Pass execution to 'onVmMain' if we are running on the VM
-- >       onVmMain __remoteTable args'
-- >
-- >     "list":sid:x509:pkey:_ -> do
-- >       -- List all available cloud services
-- >       -- (useful, but not strictly necessary for the example)
-- >       params <- defaultAzureParameters sid x509 pkey 
-- >       css <- cloudServices (azureSetup params)
-- >       mapM_ print css
-- >
-- >     cmd:sid:x509:pkey:user:cloudService:virtualMachine:port:_ -> do
-- >       -- Initialize the backend and find the right VM
-- >       params <- defaultAzureParameters sid x509 pkey 
-- >       let params' = params { azureSshUserName = user }
-- >       backend <- initializeBackend params' cloudService
-- >       Just vm <- findNamedVM backend virtualMachine
-- > 
-- >       -- The same binary can behave as the client or the server, 
-- >       -- depending on the command line arguments
-- >       case cmd of
-- >         "server" -> spawnOnVM backend vm port ($(mkClosure 'pingServer) ()) 
-- >         "client" -> callOnVM backend vm port $ 
-- >                       ProcessPair ($(mkClosure 'pingClientRemote) ()) 
-- >                                   pingClientLocal 
module Control.Distributed.Process.Backend.Azure 
  ( -- * Initialization
    Backend(..)
  , AzureParameters(..)
  , defaultAzureParameters
  , initializeBackend
    -- * Utilities
  , findNamedVM
    -- * On-VM main
  , onVmMain
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
  ) where

import Prelude hiding (catch)
import System.Environment (getEnv)
import System.FilePath ((</>), takeFileName)
import System.Environment.Executable (getExecutablePath)
import System.IO 
  ( stdout
  , hFlush
  , hSetBinaryMode
  , stdin
  , stdout
  , stderr
  , Handle
  , hClose
  )
import qualified System.Posix.Process as Posix (forkProcess, createSession)
import Data.Maybe (listToMaybe)
import Data.Binary (Binary(get, put), encode, decode)
import Data.Digest.Pure.MD5 (md5, MD5Digest)
import qualified Data.ByteString as BSS 
  ( ByteString
  , length
  , concat
  , hPut
  , hGet
  )
import qualified Data.ByteString.Char8 as BSSC (pack)
import qualified Data.ByteString.Lazy as BSL 
  ( ByteString
  , readFile
  , length
  , fromChunks
  , toChunks
  , hPut
  , hGet
  )
import Data.Typeable (Typeable)
import Data.Foldable (forM_)
import Control.Applicative ((<$>), (<*>))
import Control.Monad (void, when)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask)
import Control.Exception 
  ( Exception
  , catches
  , Handler(Handler)
  , throwIO
  , SomeException
  )
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, putMVar)

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
import Control.Distributed.Process 
  ( Process
  , Closure
  , RemoteTable
  , catch
  , unClosure
  , ProcessId
  , getSelfPid
  )
import Control.Distributed.Process.Serializable (Serializable)
import qualified Control.Distributed.Process.Internal.Types as CH 
  ( LocalNode
  , LocalProcess(processQueue)
  , Message
  , payloadToMessage
  , messageToPayload
  , createMessage
  )
import Control.Distributed.Process.Node 
  ( runProcess
  , forkProcess
  , newLocalNode
  , initRemoteTable
  )
import Control.Distributed.Process.Internal.CQueue (CQueue, enqueue)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
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
  , spawnOnVM :: VirtualMachine -> String -> RemoteProcess () -> IO ProcessId 
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
apiCallOnVM = runOnVM False

apiSpawnOnVM :: AzureParameters 
             -> String
             -> VirtualMachine 
             -> String 
             -> Closure (Backend -> Process ()) 
             -> IO ProcessId 
apiSpawnOnVM params cloudService vm port rproc = 
  runOnVM True params cloudService vm port $ 
    ProcessPair rproc localExpect
    
-- | Internal generalization of 'spawnOnVM' and 'callOnVM'
runOnVM :: Bool 
        -> AzureParameters
        -> String
        -> VirtualMachine
        -> String
        -> ProcessPair a
        -> IO a
runOnVM bg params cloudService vm port ppair = 
  withSSH2 params vm $ \s -> do
    -- TODO: reduce duplication with apiCallOnVM
    let exe = "PATH=. " ++ azureSshRemotePath params 
           ++ " onvm"
           ++ " " ++ vmIpAddress vm 
           ++ " " ++ port
           ++ " " ++ cloudService
           ++ " " ++ show bg 
           ++ " 2>&1"
    let paramsEnc = encode params
    let rprocEnc  = encode (ppairRemote ppair) 
    (status, r) <- SSH.withChannelBy (SSH.openChannelSession s) id $ \ch -> do
      SSH.channelExecute ch exe
      SSH.writeChannel ch (encodeInt32 (BSL.length rprocEnc))
      SSH.writeAllChannel ch rprocEnc 
      SSH.writeChannel ch (encodeInt32 (BSL.length paramsEnc))
      SSH.writeAllChannel ch paramsEnc 
      runLocalProcess (ppairLocal ppair) ch
    if status == 0 
      then return r 
      else error "runOnVM: Non-zero exit status" -- This would a bug 

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
-- Utilities                                                                  --
--------------------------------------------------------------------------------

-- | Find a virtual machine with a particular name
findNamedVM :: Backend -> String -> IO (Maybe VirtualMachine)
findNamedVM backend vm = 
  listToMaybe . filter ((== vm) . vmName) <$> findVMs backend 

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
         . CH.messageToPayload 
         . CH.createMessage 
         $ x 

-- | Wait for a message from the remote process (see 'ProcessPair').
-- Note that unlike for the standard Cloud Haskell 'expect' it will result in a
-- runtime error if the remote process sends a message of type other than @a@.
--
-- Since it is relatively easy for the remote process to mess up the
-- communication protocol (for instance, by doing a putStr) we ask for the
-- length twice, as some sort of sanity check. 
localExpect :: Serializable a => LocalProcess a
localExpect = LocalProcess $ do
  ch <- ask
  liftIO $ do 
    isE <- readIntChannel ch
    len <- readIntChannel ch 
    lenAgain <- readIntChannel ch 
    when (len /= lenAgain) $ throwIO (userError "Protocol violation")
    msg <- readSizeChannel ch len
    if isE /= 0
      then error (decode msg)
      else return (decode msg)

-- | Send a message from the remote process to the local process (see
-- 'ProcessPair'). Note that the remote process can use the standard Cloud
-- Haskell primitives to /receive/ messages from the local process.
remoteSend :: Serializable a => a -> Process ()
remoteSend = liftIO . remoteSend' 

remoteSend' :: Serializable a => a -> IO ()
remoteSend' = remoteSendFlagged 0

-- | If the remote process encounters an error it can use 'remoteThrow'. This
-- will cause the exception to be raised (as a user-exception, not as the
-- original type) in the local process (as well as in the remote process).
remoteThrow :: Exception e => e -> IO ()
remoteThrow e = remoteSendFlagged 1 (show e) >> throwIO e

remoteSendFlagged :: Serializable a => Int -> a -> IO ()
remoteSendFlagged flags x = do
  let enc = encode x
  BSS.hPut stdout (encodeInt32 flags)
  -- See 'localExpect' for why we send the length twice
  BSS.hPut stdout (encodeInt32 (BSL.length enc))
  BSS.hPut stdout (encodeInt32 (BSL.length enc))
  BSL.hPut stdout enc
  hFlush stdout

--------------------------------------------------------------------------------
-- On-VM main                                                                 --
--------------------------------------------------------------------------------

-- | Program main when run on the VM. A typical 'main' function looks like
--
-- > main :: IO ()
-- > main = do
-- >     args <- getArgs
-- >     case args of
-- >       "onvm":args' -> onVmMain __remoteTable args'
-- >       _ -> -- your normal main
onVmMain :: (RemoteTable -> RemoteTable) -> [String] -> IO ()
onVmMain rtable [host, port, cloudService, bg] = do
    hSetBinaryMode stdin True
    hSetBinaryMode stdout True
    Just rprocEnc  <- getWithLength stdin
    Just paramsEnc <- getWithLength stdin
    backend <- initializeBackend (decode paramsEnc) cloudService 
    let rproc = decode rprocEnc 
    lprocMVar <- newEmptyMVar :: IO (MVar CH.LocalProcess)
    if read bg 
      then
        void . Posix.forkProcess $ do
          -- We inherit the file descriptors from the parent, so the SSH
          -- session will not be terminated until we close them
          void Posix.createSession
          startCH rproc lprocMVar backend 
            (\node proc -> runProcess node $ do
              us <- getSelfPid
              liftIO $ do
                remoteSend' us
                mapM_ hClose [stdin, stdout, stderr]
              proc) 
      else do
        startCH rproc lprocMVar backend forkProcess 
        lproc <- readMVar lprocMVar
        queueFromHandle stdin (CH.processQueue lproc)
  where
    startCH :: RemoteProcess () 
            -> MVar CH.LocalProcess 
            -> Backend
            -> (CH.LocalNode -> Process () -> IO a) 
            -> IO () 
    startCH rproc lprocMVar backend go = do
      mTransport <- createTransport host port defaultTCPParameters 
      case mTransport of
        Left err -> remoteThrow err
        Right transport -> do 
          node <- newLocalNode transport (rtable initRemoteTable)
          void . go node $ do 
            ask >>= liftIO . putMVar lprocMVar
            proc <- unClosure rproc :: Process (Backend -> Process ())
            catch (proc backend) 
                  (liftIO . (remoteThrow :: SomeException -> IO ()))
onVmMain _ _ 
  = error "Invalid arguments passed on onVmMain"

-- | Read a 4-byte length @l@ and then an @l@-byte payload
--
-- Returns Nothing on EOF
getWithLength :: Handle -> IO (Maybe BSL.ByteString)
getWithLength h = do 
  lenEnc <- BSS.hGet h 4
  if BSS.length lenEnc < 4
    then return Nothing
    else do
      let len = decodeInt32 lenEnc
      bs <- BSL.hGet h len
      if BSL.length bs < fromIntegral len
        then return Nothing
        else return (Just bs)

queueFromHandle :: Handle -> CQueue CH.Message -> IO ()
queueFromHandle h q = do
  mPayload <- getWithLength stdin 
  forM_ mPayload $ \payload -> do
    enqueue q $ CH.payloadToMessage (BSL.toChunks payload) 
    queueFromHandle h q

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
