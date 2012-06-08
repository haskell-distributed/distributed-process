module Main where 

import Prelude hiding (catch)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar ( newEmptyMVar
                               , putMVar
                               , takeMVar
                               , readMVar
                               )
import Control.Exception (catch)                               
import Control.Monad (replicateM_)
import Control.Distributed.Process
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)

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

    putStrLn $ "Client did " ++ show numPings ++ " pings"
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

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  -- testPing transport
  testMonitor1 transport
  testMonitor2 transport
