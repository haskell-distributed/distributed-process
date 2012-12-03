{-# LANGUAGE TemplateHaskell #-}
module Main where

import Data.ByteString.Lazy (empty)
import Data.Typeable (Typeable)
import Control.Monad (join, replicateM, forever, replicateM_, void)
import Control.Exception (IOException, throw)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , readMVar
  , takeMVar
  , putMVar
  , modifyMVar_
  , newMVar
  )
import Control.Applicative ((<$>))
import System.Random (randomIO)
import Network.Transport (Transport)
import Network.Transport.TCP
  ( createTransportExposeInternals
  , defaultTCPParameters
  , TransportInternals(socketBetween)
  )
import Network.Socket (sClose)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types (NodeId(nodeAddress))
import Control.Distributed.Static (staticLabel, staticClosure)

import Test.HUnit (Assertion)
import Test.Framework (Test, defaultMain)
import Test.Framework.Providers.HUnit (testCase)

--------------------------------------------------------------------------------
-- Supporting definitions                                                     --
--------------------------------------------------------------------------------

quintuple :: a -> b -> c -> d -> e -> (a, b, c, d, e)
quintuple a b c d e = (a, b, c, d, e)

sdictInt :: SerializableDict Int
sdictInt = SerializableDict

factorial :: Int -> Process Int
factorial 0 = return 1
factorial n = (n *) <$> factorial (n - 1)

addInt :: Int -> Int -> Int
addInt x y = x + y

putInt :: Int -> MVar Int -> IO ()
putInt = flip putMVar

sendPid :: ProcessId -> Process ()
sendPid toPid = do
  fromPid <- getSelfPid
  send toPid fromPid

wait :: Int -> Process ()
wait = liftIO . threadDelay

isPrime :: Integer -> Process Bool
isPrime n = return . (n `elem`) . takeWhile (<= n) . sieve $ [2..]
  where
    sieve :: [Integer] -> [Integer]
    sieve (p : xs) = p : sieve [x | x <- xs, x `mod` p > 0]
    sieve [] = error "Uh oh -- we've run out of primes"

-- | First argument indicates empty closure environment
typedPingServer :: () -> ReceivePort (SendPort ()) -> Process ()
typedPingServer () rport = forever $ do
  sport <- receiveChan rport
  sendChan sport ()

signal :: ProcessId -> Process ()
signal pid = send pid ()

remotable [ 'factorial
          , 'addInt
          , 'putInt
          , 'sendPid
          , 'sdictInt
          , 'wait
          , 'typedPingServer
          , 'isPrime
          , 'quintuple
          , 'signal
          ]

randomElement :: [a] -> IO a
randomElement xs = do
  ix <- randomIO
  return (xs !! (ix `mod` length xs))

remotableDecl [
    [d| dfib :: ([NodeId], SendPort Integer, Integer) -> Process () ;
        dfib (_, reply, 0) = sendChan reply 0
        dfib (_, reply, 1) = sendChan reply 1
        dfib (nids, reply, n) = do
          nid1 <- liftIO $ randomElement nids
          nid2 <- liftIO $ randomElement nids
          (sport, rport) <- newChan
          spawn nid1 $ $(mkClosure 'dfib) (nids, sport, n - 2)
          spawn nid2 $ $(mkClosure 'dfib) (nids, sport, n - 1)
          n1 <- receiveChan rport
          n2 <- receiveChan rport
          sendChan reply $ n1 + n2
      |]
  ]

-- Just try creating a static polymorphic value
staticQuintuple :: (Typeable a, Typeable b, Typeable c, Typeable d, Typeable e)
                => Static (a -> b -> c -> d -> e -> (a, b, c, d, e))
staticQuintuple = $(mkStatic 'quintuple)

factorialClosure :: Int -> Closure (Process Int)
factorialClosure = $(mkClosure 'factorial)

addIntClosure :: Int -> Closure (Int -> Int)
addIntClosure = $(mkClosure 'addInt)

putIntClosure :: Int -> Closure (MVar Int -> IO ())
putIntClosure = $(mkClosure 'putInt)

sendPidClosure :: ProcessId -> Closure (Process ())
sendPidClosure = $(mkClosure 'sendPid)

sendFac :: Int -> ProcessId -> Closure (Process ())
sendFac n pid = factorialClosure n `bindCP` cpSend $(mkStatic 'sdictInt) pid

factorialOf :: Closure (Int -> Process Int)
factorialOf = staticClosure $(mkStatic 'factorial)

factorial' :: Int -> Closure (Process Int)
factorial' n = returnCP $(mkStatic 'sdictInt) n `bindCP` factorialOf

waitClosure :: Int -> Closure (Process ())
waitClosure = $(mkClosure 'wait)

simulateNetworkFailure :: TransportInternals -> NodeId -> NodeId -> Process ()
simulateNetworkFailure transportInternals fr to = liftIO $ do
  threadDelay 10000
  sock <- socketBetween transportInternals (nodeAddress fr) (nodeAddress to)
  sClose sock
  threadDelay 10000

--------------------------------------------------------------------------------
-- The tests proper                                                           --
--------------------------------------------------------------------------------

testUnclosure :: Transport -> RemoteTable -> Assertion
testUnclosure transport rtable = do
  node <- newLocalNode transport rtable
  done <- newEmptyMVar
  forkProcess node $ do
    120 <- join . unClosure $ factorialClosure 5
    liftIO $ putMVar done ()
  takeMVar done

testBind :: Transport -> RemoteTable -> Assertion
testBind transport rtable = do
  node <- newLocalNode transport rtable
  done <- newEmptyMVar
  runProcess node $ do
    us <- getSelfPid
    join . unClosure $ sendFac 6 us
    (720 :: Int) <- expect
    liftIO $ putMVar done ()
  takeMVar done

testSendPureClosure :: Transport -> RemoteTable -> Assertion
testSendPureClosure transport rtable = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode transport rtable
    addr <- forkProcess node $ do
      cl <- expect
      fn <- unClosure cl :: Process (Int -> Int)
      13 <- return $ fn 6
      liftIO $ putMVar serverDone ()
    putMVar serverAddr addr

  forkIO $ do
    node <- newLocalNode transport rtable
    theirAddr <- readMVar serverAddr
    runProcess node $ send theirAddr (addIntClosure 7)

  takeMVar serverDone

testSendIOClosure :: Transport -> RemoteTable -> Assertion
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
    runProcess node $ send theirAddr (putIntClosure 5)

  takeMVar serverDone

testSendProcClosure :: Transport -> RemoteTable -> Assertion
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
      send theirAddr (cpSend $(mkStatic 'sdictInt) pid)
      5 <- expect :: Process Int
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

testSpawn :: Transport -> RemoteTable -> Assertion
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
      pid'  <- spawn nid (sendPidClosure pid)
      pid'' <- expect
      True <- return $ pid' == pid''
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

testCall :: Transport -> RemoteTable -> Assertion
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
      (120 :: Int) <- call $(mkStatic 'sdictInt) nid (factorialClosure 5)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

testCallBind :: Transport -> RemoteTable -> Assertion
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
      (120 :: Int) <- call $(mkStatic 'sdictInt) nid (factorial' 5)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

testSeq :: Transport -> RemoteTable -> Assertion
testSeq transport rtable = do
  node <- newLocalNode transport rtable
  done <- newEmptyMVar
  runProcess node $ do
    us <- getSelfPid
    join . unClosure $ sendFac 5 us `seqCP` sendFac 6 us
    120 :: Int <- expect
    720 :: Int <- expect
    liftIO $ putMVar done ()
  takeMVar done

-- Test 'spawnSupervised'
--
-- Set up a supervisor, spawn a child, then have a third process monitor the
-- child. The supervisor then throws an exception, the child dies because it
-- was linked to the supervisor, and the third process notices that the child
-- dies.
testSpawnSupervised :: Transport -> RemoteTable -> Assertion
testSpawnSupervised transport rtable = do
    [node1, node2]       <- replicateM 2 $ newLocalNode transport rtable
    [superPid, childPid] <- replicateM 2 $ newEmptyMVar
    thirdProcessDone     <- newEmptyMVar

    forkProcess node1 $ do
      us <- getSelfPid
      liftIO $ putMVar superPid us
      (child, _ref) <- spawnSupervised (localNodeId node2) (waitClosure 1000000)
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

testSpawnInvalid :: Transport -> RemoteTable -> Assertion
testSpawnInvalid transport rtable = do
  node <- newLocalNode transport rtable
  done <- newEmptyMVar
  forkProcess node $ do
    (pid, ref) <- spawnMonitor (localNodeId node) (closure (staticLabel "ThisDoesNotExist") empty)
    ProcessMonitorNotification ref' pid' _reason <- expect
    -- Depending on the exact interleaving, reason might be NoProc or the exception thrown by the absence of the static closure
    True <- return $ ref' == ref && pid == pid'
    liftIO $ putMVar done ()
  takeMVar done

testClosureExpect :: Transport -> RemoteTable -> Assertion
testClosureExpect transport rtable = do
  node <- newLocalNode transport rtable
  done <- newEmptyMVar
  runProcess node $ do
    nodeId <- getSelfNode
    us     <- getSelfPid
    them   <- spawn nodeId $ cpExpect $(mkStatic 'sdictInt) `bindCP` cpSend $(mkStatic 'sdictInt) us
    send them (1234 :: Int)
    (1234 :: Int) <- expect
    liftIO $ putMVar done ()
  takeMVar done

testSpawnChannel :: Transport -> RemoteTable -> Assertion
testSpawnChannel transport rtable = do
  done <- newEmptyMVar
  [node1, node2] <- replicateM 2 $ newLocalNode transport rtable

  forkProcess node1 $ do
    pingServer <- spawnChannel
                    (sdictSendPort sdictUnit)
                    (localNodeId node2)
                    ($(mkClosure 'typedPingServer) ())
    (sendReply, receiveReply) <- newChan
    sendChan pingServer sendReply
    receiveChan receiveReply
    liftIO $ putMVar done ()

  takeMVar done

testTDict :: Transport -> RemoteTable -> Assertion
testTDict transport rtable = do
  done <- newEmptyMVar
  [node1, node2] <- replicateM 2 $ newLocalNode transport rtable
  forkProcess node1 $ do
    True <- call $(functionTDict 'isPrime) (localNodeId node2) ($(mkClosure 'isPrime) (79 :: Integer))
    liftIO $ putMVar done ()
  takeMVar done

testFib :: Transport -> RemoteTable -> Assertion
testFib transport rtable = do
  nodes <- replicateM 4 $ newLocalNode transport rtable
  done <- newEmptyMVar

  forkProcess (head nodes) $ do
    (sport, rport) <- newChan
    spawnLocal $ dfib (map localNodeId nodes, sport, 10)
    55 <- receiveChan rport :: Process Integer
    liftIO $ putMVar done ()

  takeMVar done

testSpawnReconnect :: Transport -> RemoteTable -> TransportInternals -> Assertion
testSpawnReconnect transport rtable transportInternals = do
  [node1, node2] <- replicateM 2 $ newLocalNode transport rtable
  let nid1 = localNodeId node1
      nid2 = localNodeId node2
  done <- newEmptyMVar
  iv <- newMVar (0 :: Int)

  incr <- forkProcess node1 $ forever $ do
    () <- expect
    liftIO $ modifyMVar_ iv (return . (+ 1))

  forkProcess node2 $ do
    _pid1 <- spawn nid1 ($(mkClosure 'signal) incr)
    simulateNetworkFailure transportInternals nid2 nid1
    _pid2 <- spawn nid1 ($(mkClosure 'signal) incr)
    _pid3 <- spawn nid1 ($(mkClosure 'signal) incr)

    liftIO $ threadDelay 100000

    count <- liftIO $ takeMVar iv
    True <- return $ count == 2 || count == 3 -- It depends on which message we get first in 'spawn'

    liftIO $ putMVar done ()

  takeMVar done

-- | 'spawn' used to ave a race condition which would be triggered if the
-- spawning process terminates immediately after spawning
testSpawnTerminate :: Transport -> RemoteTable -> Assertion
testSpawnTerminate transport rtable = do
  slave  <- newLocalNode transport rtable
  master <- newLocalNode transport rtable
  masterDone <- newEmptyMVar

  runProcess master $ do
    us <- getSelfPid
    replicateM_ 1000 . spawnLocal . void . spawn (localNodeId slave) $ $(mkClosure 'signal) us
    replicateM_ 1000 $ (expect :: Process ())
    liftIO $ putMVar masterDone ()

  takeMVar masterDone

tests :: (Transport, TransportInternals) -> RemoteTable -> [Test]
tests (transport, transportInternals) rtable = [
    testCase "Unclosure"       (testUnclosure       transport rtable)
  , testCase "Bind"            (testBind            transport rtable)
  , testCase "SendPureClosure" (testSendPureClosure transport rtable)
  , testCase "SendIOClosure"   (testSendIOClosure   transport rtable)
  , testCase "SendProcClosure" (testSendProcClosure transport rtable)
  , testCase "Spawn"           (testSpawn           transport rtable)
  , testCase "Call"            (testCall            transport rtable)
  , testCase "CallBind"        (testCallBind        transport rtable)
  , testCase "Seq"             (testSeq             transport rtable)
  , testCase "SpawnSupervised" (testSpawnSupervised transport rtable)
  , testCase "SpawnInvalid"    (testSpawnInvalid    transport rtable)
  , testCase "ClosureExpect"   (testClosureExpect   transport rtable)
  , testCase "SpawnChannel"    (testSpawnChannel    transport rtable)
  , testCase "TDict"           (testTDict           transport rtable)
  , testCase "Fib"             (testFib             transport rtable)
  , testCase "SpawnTerminate"  (testSpawnTerminate  transport rtable)
  , testCase "SpawnReconnect"  (testSpawnReconnect  transport rtable transportInternals)
  ]


main :: IO ()
main = do
  Right transport <- createTransportExposeInternals "127.0.0.1" "8080" defaultTCPParameters
  let rtable = __remoteTable . __remoteTableDecl $ initRemoteTable
  defaultMain (tests transport rtable)
