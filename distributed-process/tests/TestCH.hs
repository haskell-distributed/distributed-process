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
import Control.Distributed.Process
import Control.Monad.IO.Class (liftIO)
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
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

-- | Set up monitoring, send first message to an unreachable node 
testMonitor1 :: NT.Transport -> IO ()
testMonitor1 transport = do
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
      monitor theirAddr MaMonitor
      send theirAddr "Hi"
      ProcessMonitorException pid SrNoPing <- expect
      True <- return $ pid == theirAddr
      return ()
    putMVar done ()
      
  takeMVar done

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
      return ()
    putMVar done ()
      
  takeMVar done

-- TODO: test/specify normal process termination

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  runTests 
    [ -- ("Ping",     testPing transport)
      ("Monitor1", testMonitor1 transport)
    , ("Monitor2", testMonitor2 transport)
    , ("Monitor3", testMonitor3 transport)
    ]
