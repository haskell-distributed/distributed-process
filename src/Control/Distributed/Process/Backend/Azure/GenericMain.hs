-- | Generic main
module Control.Distributed.Process.Backend.Azure.GenericMain 
  ( genericMain
  , ProcessPair(..)
  ) where

import Prelude hiding (catch)
import System.Exit (exitSuccess, exitFailure)
import System.IO 
  ( hFlush
  , stdout
  , stdin
  , stderr
  , hSetBinaryMode
  , hClose
  , Handle
  )
import Data.Foldable (forM_)
import Data.Binary (decode)  
import qualified Data.ByteString.Lazy as BSL (ByteString, hGet, toChunks, length)
import qualified Data.ByteString as BSS (hGet, length)
import Control.Monad (unless, forM, void)
import Control.Monad.Reader (ask)
import Control.Exception (SomeException)
import Control.Applicative ((<$>), (<*>), optional)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)

-- Posix
import qualified System.Posix.Process as Posix (forkProcess, createSession)

-- SSH
import qualified Network.SSH.Client.LibSSH2.Foreign as SSH
  ( initialize 
  , exit
  )

-- Command line options
import Options.Applicative 
  ( Parser
  , strOption
  , long
  , (&)
  , metavar
  , help
  , subparser
  , command
  , info
  , progDesc 
  , execParser
  , helper
  , fullDesc
  , header
  , switch
  )

-- CH
import Control.Distributed.Process 
  ( RemoteTable
  , Process
  , unClosure
  , catch
  )
import Control.Distributed.Process.Node 
  ( newLocalNode
  , runProcess
  , forkProcess
  , initRemoteTable
  , LocalNode
  )
import Control.Distributed.Process.Internal.Types
  ( LocalProcess(processQueue)
  , payloadToMessage
  , Message
  )
import Control.Distributed.Process.Internal.CQueue (CQueue, enqueue)

-- Azure
import Control.Distributed.Process.Backend.Azure 
  ( AzureParameters(azureSshUserName, azureSetup)
  , defaultAzureParameters
  , initializeBackend 
  , cloudServices 
  , VirtualMachine(vmName)
  , Backend(findVMs, copyToVM, checkMD5, callOnVM, spawnOnVM)
  , ProcessPair(..)
  , RemoteProcess
  , remoteThrow
  )

-- Transport
import Network.Transport.Internal (decodeInt32)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

--------------------------------------------------------------------------------
-- Main                                                                       -- 
--------------------------------------------------------------------------------

genericMain :: (RemoteTable -> RemoteTable)       -- ^ Standard CH remote table 
            -> (String -> IO (ProcessPair ()))    -- ^ Closures to support in 'run'
            -> (String -> IO (RemoteProcess ()))  -- ^ Closures to support in @run --background@ 
            -> IO ()
genericMain remoteTable callable spawnable = do 
    _ <- SSH.initialize True
    cmd <- execParser opts
    case cmd of
      List {} -> do
        params <- azureParameters (azureOptions cmd) Nothing
        css <- cloudServices (azureSetup params) 
        mapM_ print css
      CopyTo {} -> do
        params  <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params (targetService (target cmd))
        vms     <- findMatchingVMs backend (targetVM (target cmd))
        forM_ vms $ \vm -> do
          putStr (vmName vm ++ ": ") >> hFlush stdout 
          copyToVM backend vm 
          putStrLn "Done"
      CheckMD5 {} -> do
        params  <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params (targetService (target cmd))
        vms     <- findMatchingVMs backend (targetVM (target cmd))
        matches <- forM vms $ \vm -> do
          unless (status cmd) $ putStr (vmName vm ++ ": ") >> hFlush stdout
          match <- checkMD5 backend vm 
          unless (status cmd) $ putStrLn $ if match then "OK" else "FAILED"
          return match
        if and matches
          then exitSuccess
          else exitFailure
      RunOn {} | background cmd -> do
        params  <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params (targetService (target cmd))
        vms     <- findMatchingVMs backend (targetVM (target cmd))
        rProc   <- spawnable (closureId cmd)
        forM_ vms $ \vm -> do
          putStr (vmName vm ++ ": ") >> hFlush stdout 
          spawnOnVM backend vm (remotePort cmd) rProc
          putStrLn "OK"
      RunOn {} {- not (background cmd) -} -> do 
        params  <- azureParameters (azureOptions cmd) (Just (sshOptions cmd))
        backend <- initializeBackend params (targetService (target cmd))
        vms     <- findMatchingVMs backend (targetVM (target cmd))
        procPair <- callable (closureId cmd)
        forM_ vms $ \vm -> do
          putStr (vmName vm ++ ": ") >> hFlush stdout 
          callOnVM backend vm (remotePort cmd) procPair
      OnVmCommand (vmCmd@OnVmRun {}) ->
        onVmRun (remoteTable initRemoteTable) 
                (onVmIP vmCmd) 
                (onVmPort vmCmd)
                (onVmService vmCmd)
                (onVmBackground vmCmd)
    SSH.exit
  where
    opts = info (helper <*> commandParser)
      ( fullDesc 
      & header "Cloud Haskell backend for Azure"
      )

findMatchingVMs :: Backend -> Maybe String -> IO [VirtualMachine]
findMatchingVMs backend Nothing   = findVMs backend
findMatchingVMs backend (Just vm) = filter ((== vm) . vmName) `fmap` findVMs backend  

azureParameters :: AzureOptions -> Maybe SshOptions -> IO AzureParameters
azureParameters opts Nothing = 
  defaultAzureParameters (subscriptionId opts)
                         (pathToCert opts)
                         (pathToKey opts)
azureParameters opts (Just sshOpts) = do
  params <- defaultAzureParameters (subscriptionId opts)
                         (pathToCert opts)
                         (pathToKey opts)
  return params { 
      azureSshUserName = remoteUser sshOpts
    }

--------------------------------------------------------------------------------
-- Executing a closure on the VM                                              --
--------------------------------------------------------------------------------

onVmRun :: RemoteTable -> String -> String -> String -> Bool -> IO ()
onVmRun rtable host port cloudService bg = do
    hSetBinaryMode stdin True
    hSetBinaryMode stdout True
    Just procEnc   <- getWithLength stdin
    Just paramsEnc <- getWithLength stdin
    backend <- initializeBackend (decode paramsEnc) cloudService 
    let proc = decode procEnc 
    lprocMVar <- newEmptyMVar :: IO (MVar LocalProcess)
    if bg 
      then detach $ startCH proc lprocMVar backend runProcess (\_ -> return ()) 
      else do
        startCH proc lprocMVar backend forkProcess (liftIO . remoteThrow)
        lproc <- readMVar lprocMVar
        queueFromHandle stdin (processQueue lproc)
  where
    startCH :: RemoteProcess () 
            -> MVar LocalProcess 
            -> Backend
            -> (LocalNode -> Process () -> IO a) 
            -> (SomeException -> Process ())
            -> IO () 
    startCH rproc lprocMVar backend go exceptionHandler = do
      mTransport <- createTransport host port defaultTCPParameters 
      case mTransport of
        Left err -> remoteThrow err
        Right transport -> do 
          node <- newLocalNode transport rtable
          void . go node $ do 
            ask >>= liftIO . putMVar lprocMVar
            proc <- unClosure rproc :: Process (Backend -> Process ())
            catch (proc backend) exceptionHandler

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

queueFromHandle :: Handle -> CQueue Message -> IO ()
queueFromHandle h q = do
  mPayload <- getWithLength stdin 
  forM_ mPayload $ \payload -> do
    enqueue q $ payloadToMessage (BSL.toChunks payload) 
    queueFromHandle h q

detach :: IO () -> IO ()
detach io = do 
  mapM_ hClose [stdin, stdout, stderr]
  void . Posix.forkProcess $ void Posix.createSession >> io

--------------------------------------------------------------------------------
-- Command line options                                                       --
--------------------------------------------------------------------------------

data AzureOptions = AzureOptions {
    subscriptionId :: String
  , pathToCert     :: FilePath
  , pathToKey      :: FilePath
  }
  deriving Show

data SshOptions = SshOptions {
    remoteUser :: String
  }
  deriving Show

data Target = Target {
    targetService :: String
  , targetVM      :: Maybe String
  }
  deriving Show

data Command = 
    List { 
        azureOptions :: AzureOptions 
      }
  | CopyTo { 
        azureOptions :: AzureOptions 
      , sshOptions   :: SshOptions 
      , target       :: Target 
      }
  | CheckMD5 {
        azureOptions :: AzureOptions
      , sshOptions   :: SshOptions 
      , target       :: Target 
      , status       :: Bool
      } 
  | RunOn { 
        azureOptions :: AzureOptions 
      , sshOptions   :: SshOptions 
      , target       :: Target 
      , remotePort   :: String 
      , closureId    :: String
      , background   :: Bool
      }
  | OnVmCommand {
       _onVmCommand  :: OnVmCommand
      }
  deriving Show

data OnVmCommand =
    OnVmRun {
      onVmIP         :: String
    , onVmPort       :: String
    , onVmService    :: String
    , onVmBackground :: Bool
    }
  deriving Show

azureOptionsParser :: Parser AzureOptions
azureOptionsParser = AzureOptions 
  <$> strOption ( long "subscription-id"
                & metavar "SID" 
                & help "Azure subscription ID"
                )
  <*> strOption ( long "certificate"
                & metavar "CERT"
                & help "X509 certificate"
                )
  <*> strOption ( long "private"
                & metavar "PRI"
                & help "Private key in PKCS#1 format"
                )

sshOptionsParser :: Parser SshOptions
sshOptionsParser = SshOptions 
  <$> strOption ( long "user"
                & metavar "USER"
                & help "Remove SSH username"
                )

listParser :: Parser Command
listParser = List <$> azureOptionsParser

copyToParser :: Parser Command
copyToParser = CopyTo 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> targetParser

targetParser :: Parser Target
targetParser = Target 
  <$> strOption ( long "cloud-service"
                & metavar "CS"
                & help "Cloud service name"
                )
  <*> optional (strOption ( long "virtual-machine"
                          & metavar "VM"
                          & help "Virtual machine name (all VMs if unspecified)"
                          ))

checkMD5Parser :: Parser Command
checkMD5Parser = CheckMD5 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> targetParser 
  <*> switch ( long "status"
             & help "Don't output anything, status code shows success"
             )

commandParser :: Parser Command
commandParser = subparser
  ( command "list"  (info listParser 
      (progDesc "List Azure cloud services"))
  & command "install" (info copyToParser
      (progDesc "Install the executable"))
  & command "md5" (info checkMD5Parser 
      (progDesc "Check if the remote and local MD5 hash match"))
  & command "run" (info runOnParser
      (progDesc "Run the executable"))
  & command "onvm" (info onVmCommandParser
      (progDesc "Commands used when running ON the vm (usually used internally only)"))
  )

runOnParser :: Parser Command
runOnParser = RunOn 
  <$> azureOptionsParser
  <*> sshOptionsParser
  <*> targetParser 
  <*> strOption ( long "port"
                & metavar "PORT"
                & help "Port number of the CH instance"
                )
  <*> strOption ( long "closure"
                & metavar "PROC"
                & help "Process to run on the CH instance"
                )
  <*> switch ( long "background"
             & help "Run the process in the background"
             )

onVmRunParser :: Parser OnVmCommand
onVmRunParser = OnVmRun 
  <$> strOption ( long "host"
                & metavar "IP"
                & help "IP address"
                )
  <*> strOption ( long "port"
                & metavar "PORT"
                & help "port number"
                )
  <*> strOption ( long "cloud-service"
                & metavar "CS"
                & help "Cloud service name"
                )
  <*> switch ( long "background"
             & help "Run the process in the background"
             )

onVmCommandParser :: Parser Command
onVmCommandParser = OnVmCommand <$> subparser
  ( command "run" (info onVmRunParser
      (progDesc "Run the executable"))
  )


