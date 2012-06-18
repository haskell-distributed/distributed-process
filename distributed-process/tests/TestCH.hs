module Main where 

import Prelude hiding (catch)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Data.Foldable (forM_)
import qualified Data.Map as Map (empty)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar ( MVar
                               , newEmptyMVar
                               , putMVar
                               , takeMVar
                               , readMVar
                               )
import Control.Monad (replicateM_)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (throwIO)
import Control.Applicative ((<$>))
import qualified Network.Transport as NT (Transport, closeEndPoint)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process
import Control.Distributed.Process.Internal (LocalNode(localEndPoint))
import TestAuxiliary

newtype Ping = Ping ProcessId
  deriving (Typeable, Binary, Show)

newtype Pong = Pong ProcessId
  deriving (Typeable, Binary, Show)

-- | The ping server from the paper
ping :: Process ()
ping = do
  Pong partner <- expect
  self <- getSelfPid
  send partner (Ping self)
  ping

-- | Basic ping test
testPing :: NT.Transport -> IO ()
testPing transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    pingServer <- readMVar serverAddr

    let numPings = 10000

    runProcess localNode $ do
      pid <- getSelfPid
      replicateM_ numPings $ do
        send pingServer (Pong pid)
        Ping _ <- expect
        return ()

    putMVar clientDone ()

  takeMVar clientDone

-- | Monitor or link to a remote node
monitorOrLink :: Bool            -- ^ 'True' for monitor, 'False' for link
              -> ProcessId       -- Process to monitor/link to
              -> Maybe (MVar ()) -- MVar to signal on once the monitor has been set up
              -> Process (Maybe MonitorRef) 
monitorOrLink mOrL pid mSignal = do
  result <- if mOrL then Just <$> monitor pid
                    else link pid >> return Nothing
  -- Monitor is asynchronous, which usually does not matter but if we want a
  -- *specific* signal then it does. Therefore we wait an arbitrary delay and
  -- hope that this means the monitor has been set up
  forM_ mSignal $ \signal -> liftIO . forkIO $ threadDelay 100000 >> putMVar signal ()
  return result

monitorTestProcess :: ProcessId       -- Process to monitor/link to
                   -> Bool            -- 'True' for monitor, 'False' for link
                   -> Bool            -- Should we unmonitor?
                   -> DiedReason      -- Expected cause of death
                   -> Maybe (MVar ()) -- Signal for 'monitor set up' 
                   -> MVar ()         -- Signal for successful termination
                   -> Process ()
monitorTestProcess theirAddr mOrL un reason monitorSetup done = 
  catch (do mRef <- monitorOrLink mOrL theirAddr monitorSetup 
            case (un, mRef) of
              (True, Nothing) -> do
                unlink theirAddr
                DidUnlink pid <- expect
                True <- return $ pid == theirAddr
                liftIO $ putMVar done ()
              (True, Just ref) -> do
                unmonitor ref
                DidUnmonitor ref' <- expect
                True <- return $ ref == ref'
                liftIO $ putMVar done ()
              (False, ref) -> do
                MonitorNotification ref' pid reason' <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL && reason == reason'
                liftIO $ putMVar done ()
        )
        (\(LinkException pid reason') -> do
            True <- return $ pid == theirAddr && not mOrL && not un && reason == reason'
            liftIO $ putMVar done ()
        )
  

-- | Monitor an unreachable node 
testMonitorUnreachable :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorUnreachable transport mOrL un = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000 
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar deadProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un DiedDisconnect Nothing done 

  takeMVar done

-- | Monitor a process which terminates normally
testMonitorNormalTermination :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorNormalTermination transport mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode $ 
      liftIO $ readMVar monitorSetup
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $ 
      monitorTestProcess theirAddr mOrL un DiedNormal (Just monitorSetup) done

  takeMVar done

-- | Monitor a process which terminates abnormally
testMonitorAbnormalTermination :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorAbnormalTermination transport mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  let err = userError "Abnormal termination"

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode . liftIO $ do
      readMVar monitorSetup
      throwIO err 
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $ 
      monitorTestProcess theirAddr mOrL un (DiedException (show err)) (Just monitorSetup) done

  takeMVar done
    
-- | Monitor a local process that is already dead
testMonitorLocalDeadProcess :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorLocalDeadProcess transport mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  localNode <- newLocalNode transport Map.empty
  done <- newEmptyMVar

  forkIO $ do
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedNoProc Nothing done

  takeMVar done

-- | Monitor a remote process that is already dead
testMonitorRemoteDeadProcess :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorRemoteDeadProcess transport mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedNoProc Nothing done

  takeMVar done

-- | Monitor a process that becomes disconnected
testMonitorDisconnect :: NT.Transport -> Bool -> Bool -> IO ()
testMonitorDisconnect transport mOrL un = do
  processAddr <- newEmptyMVar
  monitorSetup <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000 
    putMVar processAddr addr
    readMVar monitorSetup
    NT.closeEndPoint (localEndPoint localNode)

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar processAddr
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedDisconnect (Just monitorSetup) done
  
  takeMVar done


{-
-- Like 'testMonitor1', but throw an exception instead
testMonitor2 :: NT.Transport -> IO ()
testMonitor2 transport = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    addr <- forkProcess localNode $ return ()
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar deadProcess
    runProcess localNode $ do
      monitor theirAddr MaLink
      pcatch (send theirAddr "Hi") $ \(ProcessMonitorException pid SrNoPing) -> do 
        True <- return $ pid == theirAddr
        return ()
    putMVar done ()
      
  takeMVar done

-- The first send succeeds, connection is set up, but then the second send
-- fails. 
--
-- TODO: should we specify that we receive exactly one notification per process
-- failure?
testMonitor3 :: NT.Transport -> IO ()
testMonitor3 transport = do
  firstSend <- newEmptyMVar
  serverAddr <- newEmptyMVar
  serverDead <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    -- TODO: what happens when processes terminate? 
    addr <- forkProcess localNode $ return ()
    putMVar serverAddr addr
    readMVar firstSend
    closeLocalNode localNode
    threadDelay 10000 -- Give the TCP layer a chance to actually close the socket
    putMVar serverDead ()

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar serverAddr 
    runProcess localNode $ do 
      monitor theirAddr MaMonitor
      send theirAddr "Hi"
      liftIO $ putMVar firstSend () >> readMVar serverDead
      send theirAddr "Ho"
      ProcessMonitorException pid SrNoPing <- expect
      True <- return $ pid == theirAddr
      -- We should not receive a second exception
      send theirAddr "Hey"
      Nothing <- expectTimeout 1000000 :: Process (Maybe ProcessMonitorException) 
      return ()
    putMVar done ()
      
  takeMVar done


-- Like testMonitor3, except without the second send (so we must detect the
-- failure elsewhere) 
testMonitor4 :: NT.Transport -> IO ()
testMonitor4 transport = do
  firstSend <- newEmptyMVar
  serverAddr <- newEmptyMVar
  serverDead <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    -- TODO: what happens when processes terminate? 
    addr <- forkProcess localNode $ return ()
    putMVar serverAddr addr
    readMVar firstSend
    closeLocalNode localNode
    threadDelay 10000 -- Give the TCP layer a chance to actually close the socket
    putMVar serverDead ()

  forkIO $ do
    localNode <- newLocalNode transport Map.empty
    theirAddr <- readMVar serverAddr 
    runProcess localNode $ do 
      monitor theirAddr MaMonitor
      send theirAddr "Hi"
      liftIO $ putMVar firstSend () >> readMVar serverDead
      ProcessMonitorException pid SrNoPing <- expect
      True <- return $ pid == theirAddr
      return ()
    putMVar done ()
      
  takeMVar done

-- TODO: test/specify normal process termination
-}

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  runTests 
    [ ("Ping",                     testPing transport)
      -- The "missing" combinations in the list below don't make much sense, as
      -- we cannot guarantee that the monitor reply or link exception will not 
      -- happen before the unmonitor or unlink
    , ("MonitorUnreachable",           testMonitorUnreachable         transport True  False)
    , ("MonitorNormalTermination",     testMonitorNormalTermination   transport True  False)
    , ("MonitorAbnormalTermination",   testMonitorAbnormalTermination transport True  False)
    , ("MonitorLocalDeadProcess",      testMonitorLocalDeadProcess    transport True  False)
    , ("MonitorRemoteDeadProcess",     testMonitorRemoteDeadProcess   transport True  False)
    , ("MonitorDisconnect",            testMonitorDisconnect          transport True  False)
    , ("LinkUnreachable",              testMonitorUnreachable         transport False False)
    , ("LinkNormalTermination",        testMonitorNormalTermination   transport False False)
    , ("LinkAbnormalTermination",      testMonitorAbnormalTermination transport False False)
    , ("LinkLocalDeadProcess",         testMonitorLocalDeadProcess    transport False False)
    , ("LinkRemoteDeadProcess",        testMonitorRemoteDeadProcess   transport False False)
    , ("LinkDisconnect",               testMonitorDisconnect          transport False False)
    , ("UnmonitorNormalTermination",   testMonitorNormalTermination   transport True  True)
    , ("UnmonitorAbnormalTermination", testMonitorAbnormalTermination transport True  True)
    , ("UnmonitorDisconnect",          testMonitorDisconnect          transport True  True)
    , ("UnlinkNormalTermination",      testMonitorNormalTermination   transport False True)
    , ("UnlinkAbnormalTermination",    testMonitorAbnormalTermination transport False True)
    , ("UnlinkDisconnect",             testMonitorDisconnect          transport False True)
    {-
    , ("Monitor2", testMonitor2 transport)
    , ("Monitor3", testMonitor3 transport)
    , ("Monitor4", testMonitor4 transport)
    -}
    ]
