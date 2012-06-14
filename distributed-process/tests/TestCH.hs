module Main where 

import Prelude hiding (catch)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar ( newEmptyMVar
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
    localNode <- newLocalNode transport
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport
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
monitorOrLink :: Bool -> ProcessId -> Process (Maybe MonitorRef) 
monitorOrLink True  pid = Just <$> monitor pid
monitorOrLink False pid = link pid >> return Nothing

-- | Monitor an unreachable node 
testMonitorUnreachable :: NT.Transport -> Bool -> IO ()
testMonitorUnreachable transport mOrL = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000 
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode transport
    theirAddr <- readMVar deadProcess
    runProcess localNode $
      catch (do ref <- monitorOrLink mOrL theirAddr
                MonitorNotification ref' pid DiedDisconnect <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL
                liftIO $ putMVar done ())
            (\(LinkException pid DiedDisconnect) -> do
                True <- return $ pid == theirAddr && not mOrL
                liftIO $ putMVar done ())

  takeMVar done

-- | Monitor a process which terminates normally
testMonitorNormalTermination :: NT.Transport -> Bool -> IO ()
testMonitorNormalTermination transport mOrL = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport
    addr <- forkProcess localNode $ 
      liftIO $ readMVar monitorSetup
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $ 
      catch (do ref <- monitorOrLink mOrL theirAddr
                liftIO $ do
                  -- Monitor is asynchronous, but we want to make sure the monitor has
                  -- been fully created before allowing the remote process to terminate,
                  -- otherwise we might get a different signal here 
                  threadDelay 100000
                  putMVar monitorSetup () 
                MonitorNotification ref' pid DiedNormal <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL
                liftIO $ putMVar done ())
            (\(LinkException pid DiedNormal) -> do
                True <- return $ pid == theirAddr && not mOrL
                liftIO $ putMVar done ())

  takeMVar done

-- | Monitor a process which terminates abnormally
testMonitorAbnormalTermination :: NT.Transport -> Bool -> IO ()
testMonitorAbnormalTermination transport mOrL = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  let err = userError "Abnormal termination"

  forkIO $ do
    localNode <- newLocalNode transport
    addr <- forkProcess localNode . liftIO $ do
      readMVar monitorSetup
      throwIO err 
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $ 
      catch (do ref <- monitorOrLink mOrL theirAddr
                liftIO $ do
                  -- Monitor is asynchronous, but we want to make sure the monitor has
                  -- been fully created before allowing the remote process to terminate,
                  -- otherwise we might get a different signal here 
                  threadDelay 100000
                  putMVar monitorSetup () 
                MonitorNotification ref' pid (DiedException err') <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && err' == show err && mOrL 
                liftIO $ putMVar done ())
            (\(LinkException pid (DiedException err')) -> do
                True <- return $ pid == theirAddr && err' == show err && not mOrL
                liftIO $ putMVar done ())

  takeMVar done
    
-- | Monitor a local process that is already dead
testMonitorLocalDeadProcess :: NT.Transport -> Bool -> IO ()
testMonitorLocalDeadProcess transport mOrL = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  localNode <- newLocalNode transport
  done <- newEmptyMVar

  forkIO $ do
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      catch (do ref <- monitorOrLink mOrL theirAddr
                MonitorNotification ref' pid DiedNoProc <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL
                liftIO $ putMVar done ())
            (\(LinkException pid DiedNoProc) -> do
                True <- return $ pid == theirAddr && not mOrL
                liftIO $ putMVar done ())

  takeMVar done

-- | Monitor a remote process that is already dead
testMonitorRemoteDeadProcess :: NT.Transport -> Bool -> IO ()
testMonitorRemoteDeadProcess transport mOrL = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    localNode <- newLocalNode transport
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      catch (do ref <- monitorOrLink mOrL theirAddr
                MonitorNotification ref' pid DiedNoProc <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL
                liftIO $ putMVar done ())
            (\(LinkException pid DiedNoProc) -> do
                True <- return $ pid == theirAddr && not mOrL
                liftIO $ putMVar done ())

  takeMVar done

-- | Monitor a process that becomes disconnected
testMonitorDisconnect :: NT.Transport -> Bool -> IO ()
testMonitorDisconnect transport mOrL = do
  processAddr <- newEmptyMVar
  monitorSetup <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000 
    putMVar processAddr addr
    readMVar monitorSetup
    NT.closeEndPoint (localEndPoint localNode)

  forkIO $ do
    localNode <- newLocalNode transport
    theirAddr <- readMVar processAddr
    runProcess localNode $ do
      catch (do ref <- monitorOrLink mOrL theirAddr
                liftIO $ threadDelay 100000 >> putMVar monitorSetup ()
                MonitorNotification ref' pid DiedDisconnect <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL
                liftIO $ putMVar done ())
            (\(LinkException pid DiedDisconnect) -> do
                True <- return $ pid == theirAddr && not mOrL
                liftIO $ putMVar done ())
  
  takeMVar done


{-
-- Like 'testMonitor1', but throw an exception instead
testMonitor2 :: NT.Transport -> IO ()
testMonitor2 transport = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport
    addr <- forkProcess localNode $ return ()
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode transport
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
    localNode <- newLocalNode transport
    -- TODO: what happens when processes terminate? 
    addr <- forkProcess localNode $ return ()
    putMVar serverAddr addr
    readMVar firstSend
    closeLocalNode localNode
    threadDelay 10000 -- Give the TCP layer a chance to actually close the socket
    putMVar serverDead ()

  forkIO $ do
    localNode <- newLocalNode transport
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
    localNode <- newLocalNode transport
    -- TODO: what happens when processes terminate? 
    addr <- forkProcess localNode $ return ()
    putMVar serverAddr addr
    readMVar firstSend
    closeLocalNode localNode
    threadDelay 10000 -- Give the TCP layer a chance to actually close the socket
    putMVar serverDead ()

  forkIO $ do
    localNode <- newLocalNode transport
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
    [ --("Ping",                     testPing transport)
      ("MonitorUnreachable",         testMonitorUnreachable transport True)
    , ("MonitorNormalTermination",   testMonitorNormalTermination transport True)
    , ("MonitorAbnormalTermination", testMonitorAbnormalTermination transport True)
    , ("MonitorLocalDeadProcess",    testMonitorLocalDeadProcess transport True)
    , ("MonitorRemoteDeadProcess",   testMonitorRemoteDeadProcess transport True)
    , ("MonitorDisconnect",          testMonitorDisconnect transport True)
    , ("LinkUnreachable",            testMonitorUnreachable transport False)
    , ("LinkNormalTermination",      testMonitorNormalTermination transport False)
    , ("LinkAbnormalTermination",    testMonitorAbnormalTermination transport False)
    , ("LinkLocalDeadProcess",       testMonitorLocalDeadProcess transport False)
    , ("LinkRemoteDeadProcess",      testMonitorRemoteDeadProcess transport False)
    , ("LinkDisconnect",             testMonitorDisconnect transport False)
    {-
    , ("Monitor2", testMonitor2 transport)
    , ("Monitor3", testMonitor3 transport)
    , ("Monitor4", testMonitor4 transport)
    -}
    ]
