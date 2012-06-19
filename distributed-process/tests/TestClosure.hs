module Main where

import Control.Monad.IO.Class (liftIO) 
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, takeMVar, putMVar)
import Network.Transport (Transport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import TestAuxiliary

addInt :: Int -> Int -> Int
addInt x y = x + y

putInt :: Int -> MVar Int -> IO ()
putInt = flip putMVar

sendInt :: ProcessId -> Int -> Process ()
sendInt = send

sendPid :: ProcessId -> Process ()
sendPid toPid = do
  fromPid <- getSelfPid
  send toPid fromPid

$(remotable ['addInt, 'putInt, 'sendInt, 'sendPid])

testSendPureClosure :: Transport -> RemoteTable -> IO ()
testSendPureClosure transport rtable = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar

  forkIO $ do 
    node <- newLocalNode transport rtable 
    addr <- forkProcess node $ do
      cl <- expect
      fn <- unClosure cl :: Process (Int -> Int)
      11 <- return $ fn 6
      liftIO $ putMVar serverDone () 
    putMVar serverAddr addr 

  forkIO $ do
    node <- newLocalNode transport rtable 
    theirAddr <- readMVar serverAddr
    runProcess node $ send theirAddr ($(mkClosure 'addInt) 5) 

  takeMVar serverDone

testSendIOClosure :: Transport -> RemoteTable -> IO ()
testSendIOClosure transport rtable = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar

  forkIO $ do 
    node <- newLocalNode transport rtable 
    addr <- forkProcess node $ do
      cl <- expect
      io <- unClosure cl :: Process (MVar Int -> IO ())
      liftIO $ do 
        someMVar <- newEmptyMVar
        io someMVar 
        5 <- readMVar someMVar
        putMVar serverDone () 
    putMVar serverAddr addr 

  forkIO $ do
    node <- newLocalNode transport rtable 
    theirAddr <- readMVar serverAddr
    runProcess node $ send theirAddr ($(mkClosure 'putInt) 5) 

  takeMVar serverDone

testSendProcClosure :: Transport -> RemoteTable -> IO ()
testSendProcClosure transport rtable = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do 
    node <- newLocalNode transport rtable 
    addr <- forkProcess node $ do
      cl <- expect
      pr <- unClosure cl :: Process (Int -> Process ())
      pr 5
    putMVar serverAddr addr 

  forkIO $ do
    node <- newLocalNode transport rtable 
    theirAddr <- readMVar serverAddr
    runProcess node $ do
      pid <- getSelfPid
      send theirAddr ($(mkClosure 'sendInt) pid) 
      5 <- expect :: Process Int
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

testSpawn :: Transport -> RemoteTable -> IO ()
testSpawn transport rtable = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode transport rtable
    print (localNodeId node)
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode transport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      pid   <- getSelfPid
      pid'  <- spawn nid ($(mkClosure 'sendPid) pid)
      pid'' <- expect
      True <- return $ pid' == pid''
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  let rtable = __remoteTable initRemoteTable 
  runTests 
    [ ("SendPureClosure", testSendPureClosure transport rtable)
    , ("SendIOClosure",   testSendIOClosure   transport rtable)
    , ("SendProcClosure", testSendProcClosure transport rtable)
    , ("Spawn",           testSpawn           transport rtable)
    ]
