module Main where

import Control.Monad (join)
import Control.Monad.IO.Class (liftIO) 
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, takeMVar, putMVar)
import Control.Applicative ((<$>))
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

factorial :: Int -> Process Int
factorial 0 = return 1
factorial n = (n *) <$> factorial (n - 1) 

factorialOf :: () -> Int -> Process Int
factorialOf () = factorial

returnInt :: Int -> Process Int
returnInt = return 

returnForTestApply :: (Closure (Int -> Process Int), Int) -> (Closure (Int -> Process Int), Int)
returnForTestApply = id 

$(remotable ['addInt, 'putInt, 'sendInt, 'sendPid, 'factorial, 'factorialOf, 'returnInt, 'returnForTestApply])

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

testCall :: Transport -> RemoteTable -> IO ()
testCall transport rtable = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode transport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode transport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      (120 :: Int) <- call nid ($(mkClosure 'factorial) 5)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

sendFac :: Int -> ProcessId -> Closure (Process ())
sendFac n pid = $(mkClosure 'factorial) n `cpBind` $(mkClosure 'sendInt) pid

factorial' :: Int -> Closure (Process Int)
factorial' n = $(mkClosure 'returnInt) n `cpBind` $(mkClosure 'factorialOf) ()

testBind :: Transport -> RemoteTable -> IO ()
testBind transport rtable = do
  node <- newLocalNode transport rtable
  runProcess node $ do
    us <- getSelfPid
    join . unClosure $ sendFac 6 us 
    (720 :: Int) <- expect 
    return ()

testCallBind :: Transport -> RemoteTable -> IO ()
testCallBind transport rtable = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode transport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode transport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      (120 :: Int) <- call nid (factorial' 5)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

testSeq :: Transport -> RemoteTable -> IO ()
testSeq transport rtable = do
  node <- newLocalNode transport rtable
  runProcess node $ do
    us <- getSelfPid
    join . unClosure $ sendFac 5 us `cpSeq` sendFac 6 us
    120 :: Int <- expect
    720 :: Int <- expect
    return ()

testApply :: Transport -> RemoteTable -> IO ()
testApply transport rtable = do
    node <- newLocalNode transport rtable
    runProcess node $ do
      (120 :: Int) <- join (unClosure bar)
      return ()
  where
    bar :: Closure (Process Int)
    bar = closureApply cpApply foo

    foo :: Closure (Closure (Int -> Process Int), Int)
    foo = $(mkClosure 'returnForTestApply) ($(mkClosure 'factorialOf) (), 5) 

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  let rtable = __remoteTable initRemoteTable 
  runTests 
    [ ("SendPureClosure", testSendPureClosure transport rtable)
    , ("SendIOClosure",   testSendIOClosure   transport rtable)
    , ("SendProcClosure", testSendProcClosure transport rtable)
    , ("Spawn",           testSpawn           transport rtable)
    , ("Call",            testCall            transport rtable)
    , ("Bind",            testBind            transport rtable)
    , ("CallBind",        testCallBind        transport rtable)
    , ("Seq",             testSeq             transport rtable)
    , ("Apply",           testApply           transport rtable)
    ]
