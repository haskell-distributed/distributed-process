module Main where

import qualified Data.ByteString.Lazy as BSL (empty)
import Data.Typeable (Typeable)
import Control.Monad (join, replicateM)
import Control.Exception (IOException, throw)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, takeMVar, putMVar)
import Control.Applicative ((<$>))
import Network.Transport (Transport)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types (Closure(..), Static(..), StaticLabel(..))
import TestAuxiliary

serializableDictInt :: SerializableDict Int
serializableDictInt = SerializableDict

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

returnForTestApply :: (Closure (Int -> Process Int), Int) -> (Closure (Int -> Process Int), Int)
returnForTestApply = id 

wait :: Int -> Process ()
wait = liftIO . threadDelay

first :: (a, b) -> a
first (x, _) = x

$(remotable 
  [ 'addInt
  , 'putInt
  , 'sendInt
  , 'sendPid
  , 'factorial
  , 'factorialOf
  , 'returnForTestApply
  , 'wait
  , 'serializableDictInt
  , 'first
  ])

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
      (120 :: Int) <- call serializableDictInt nid ($(mkClosure 'factorial) 5)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

sendFac :: Int -> ProcessId -> Closure (Process ())
sendFac n pid = $(mkClosure 'factorial) n `cpBind` $(mkClosure 'sendInt) pid

factorial' :: Int -> Closure (Process Int)
factorial' n = returnClosure serializableDictInt n `cpBind` $(mkClosure 'factorialOf) ()

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
      (120 :: Int) <- call serializableDictInt nid (factorial' 5)
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

-- Test 'spawnSupervised'
--
-- Set up a supervisor, spawn a child, then have a third process monitor the
-- child. The supervisor then throws an exception, the child dies because it
-- was linked to the supervisor, and the third process notices that the child
-- dies.
testSpawnSupervised :: Transport -> RemoteTable -> IO ()
testSpawnSupervised transport rtable = do
    [node1, node2]       <- replicateM 2 $ newLocalNode transport rtable
    [superPid, childPid] <- replicateM 2 $ newEmptyMVar
    thirdProcessDone     <- newEmptyMVar

    forkProcess node1 $ do
      us <- getSelfPid
      liftIO $ putMVar superPid us
      (child, _ref) <- spawnSupervised (localNodeId node2) ($(mkClosure 'wait) 1000000) 
      liftIO $ do
        putMVar childPid child
        threadDelay 500000 -- Give the child a chance to link to us
        throw supervisorDeath

    forkProcess node2 $ do
      [super, child] <- liftIO $ mapM readMVar [superPid, childPid]
      ref <- monitor child
      ProcessMonitorNotification ref' pid' (DiedException e) <- expect
      True <- return $ ref' == ref 
                    && pid' == child 
                    && e == show (ProcessLinkException super (DiedException (show supervisorDeath)))
      liftIO $ putMVar thirdProcessDone ()

    takeMVar thirdProcessDone
  where
    supervisorDeath :: IOException
    supervisorDeath = userError "Supervisor died"

testSpawnInvalid :: Transport -> RemoteTable -> IO ()
testSpawnInvalid transport rtable = do
  node <- newLocalNode transport rtable
  runProcess node $ do
    (pid, ref) <- spawnMonitor (localNodeId node) (Closure (Static (UserStatic "ThisDoesNotExist")) BSL.empty)
    ProcessMonitorNotification ref' pid' _reason <- expect 
    -- Depending on the exact interleaving, reason might be NoProc or the exception thrown by the absence of the static closure
    True <- return $ ref' == ref && pid == pid'  
    return ()

testClosureExpect :: Transport -> RemoteTable -> IO ()
testClosureExpect transport rtable = do
  node <- newLocalNode transport rtable
  runProcess node $ do
    nodeId <- getSelfNode
    us     <- getSelfPid
    them   <- spawn nodeId $ expectClosure serializableDictInt `cpBind` $(mkClosure 'sendInt) us
    send them (1234 :: Int)
    (1234 :: Int) <- expect
    return ()

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
    , ("SpawnSupervised", testSpawnSupervised transport rtable)
    , ("SpawnInvalid",    testSpawnInvalid    transport rtable)
    , ("ClosureExpect",   testClosureExpect   transport rtable)
    ]
