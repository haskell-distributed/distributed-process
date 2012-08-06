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
  )
import Data.Binary (decode)  
import qualified Data.ByteString.Lazy as BSL (getContents, length)
import Control.Monad (unless, forM, forM_, join, void)
import Control.Exception (throwIO, SomeException, evaluate)
import Control.Applicative ((<$>), (<*>), optional)
import Control.Monad.IO.Class (liftIO)

-- Posix
import System.Posix.Process (forkProcess, createSession)

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
  , Closure
  , Process
  , unClosure
  , Static
  , catch
  )
import Control.Distributed.Process.Node (newLocalNode, runProcess, initRemoteTable)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Closure (SerializableDict)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process.Backend.Azure 
  ( AzureParameters(azureSshUserName, azureSetup)
  , defaultAzureParameters
  , initializeBackend 
  , cloudServices 
  , VirtualMachine(vmName)
  , Backend(findVMs, copyToVM, checkMD5, callOnVM, spawnOnVM)
  )
import qualified Control.Distributed.Process.Backend.Azure as Azure (remoteTable)

--------------------------------------------------------------------------------
-- Main                                                                       -- 
--------------------------------------------------------------------------------

data ProcessPair b = forall a. Serializable a => ProcessPair {
    ppairRemote :: Closure (Process a)
  , ppairLocal  :: a -> IO b 
  , ppairDict   :: Static (SerializableDict a)
  }

genericMain :: (RemoteTable -> RemoteTable)           -- ^ Standard CH remote table 
            -> (String -> IO (ProcessPair ()))        -- ^ Closures to support in 'run'
            -> (String -> IO (Closure (Process ())))  -- ^ Closures to support in @run --background@ 
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
          case procPair of 
            ProcessPair rProc lProc dict -> do
              result <- callOnVM backend dict vm (remotePort cmd) rProc 
              lProc result
      OnVmCommand (vmCmd@OnVmRun {}) ->
        onVmRun (remoteTable . Azure.remoteTable $ initRemoteTable) 
                (onVmIP vmCmd) 
                (onVmPort vmCmd)
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

onVmRun :: RemoteTable -> String -> String -> Bool -> IO ()
onVmRun rtable host port bg = do
    hSetBinaryMode stdin True
    hSetBinaryMode stdout True
    procEnc <- BSL.getContents 
    -- Force evaluation (so that we can safely close stdin) 
    _length <- evaluate (BSL.length procEnc)
    let proc = decode procEnc
    if bg 
      then do
        hClose stdin
        hClose stdout
        hClose stderr
        void . forkProcess $ do
          void createSession  
          startCH proc
     else 
       startCH proc 
  where
    startCH :: Closure (Process ()) -> IO ()
    startCH proc = do
      mTransport <- createTransport host port defaultTCPParameters 
      case mTransport of
        Left err -> throwIO err
        Right transport -> do
          node <- newLocalNode transport rtable
          runProcess node $ 
            catch (join . unClosure $ proc)
                  (\e -> liftIO (print (e :: SomeException) >> throwIO e))
  
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
                          & help "Virtual machine name"
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
  <*> switch ( long "background"
             & help "Run the process in the background"
             )

onVmCommandParser :: Parser Command
onVmCommandParser = OnVmCommand <$> subparser
  ( command "run" (info onVmRunParser
      (progDesc "Run the executable"))
  )


