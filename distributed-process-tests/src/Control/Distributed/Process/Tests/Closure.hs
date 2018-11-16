{-# LANGUAGE TemplateHaskell, KindSignatures #-}
module Control.Distributed.Process.Tests.Closure (tests) where

import Network.Transport.Test (TestTransport(..))

import Data.ByteString.Lazy (empty)
import Data.IORef
import Data.Typeable (Typeable)
import Data.Maybe
import Control.Monad (join, replicateM, forever, replicateM_, void, when, unless)
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
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Internal.Types
  ( NodeId(nodeAddress)
  , createMessage
  , messageToPayload
  )
import Control.Distributed.Static (staticLabel, staticClosure)
import qualified Network.Transport as NT

import Test.HUnit (Assertion)
import Test.Framework (Test)
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

expectUnit :: Process ()
expectUnit = expect

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
          , 'expectUnit
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

simulateNetworkFailure :: TestTransport -> LocalNode -> LocalNode -> Process ()
simulateNetworkFailure TestTransport{..} from to = liftIO $ do
  m <- newEmptyMVar
  _ <- forkProcess to $ getSelfPid >>= liftIO . putMVar m
  runProcess from $ do
    them <- liftIO $ takeMVar m
    pinger <- spawnLocal $ forever $ send them ()
    _ <- monitorNode (localNodeId to)
    liftIO $ testBreakConnection (nodeAddress $ localNodeId from)
                                 (nodeAddress $ localNodeId to)
    NodeMonitorNotification _ _ _ <- expect
    kill pinger "finished"
    return ()

--------------------------------------------------------------------------------
-- The tests proper                                                           --
--------------------------------------------------------------------------------

testUnclosure :: TestTransport -> RemoteTable -> Assertion
testUnclosure TestTransport{..} rtable = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  forkProcess node $ do
    i <- join . unClosure $ factorialClosure 5
    liftIO $ putMVar done ()
    if i == 720
      then return ()
      else error "Something went horribly wrong"
  takeMVar done

testBind :: TestTransport -> RemoteTable -> Assertion
testBind TestTransport{..} rtable = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node $ do
    us <- getSelfPid
    join . unClosure $ sendFac 6 us
    (i :: Int) <- expect
    liftIO $ putMVar done ()
    if i == 720
      then return ()
      else error "Something went horribly wrong"
  takeMVar done

testSendPureClosure :: TestTransport -> RemoteTable -> Assertion
testSendPureClosure TestTransport{..} rtable = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    addr <- forkProcess node $ do
      cl <- expect
      fn <- unClosure cl :: Process (Int -> Int)
      (_ :: Int) <- return $ fn 6
      liftIO $ putMVar serverDone ()
    putMVar serverAddr addr

  forkIO $ do
    node <- newLocalNode testTransport rtable
    theirAddr <- readMVar serverAddr
    runProcess node $ send theirAddr (addIntClosure 7)

  takeMVar serverDone

testSendIOClosure :: TestTransport -> RemoteTable -> Assertion
testSendIOClosure TestTransport{..} rtable = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    addr <- forkProcess node $ do
      cl <- expect
      io <- unClosure cl :: Process (MVar Int -> IO ())
      liftIO $ do
        someMVar <- newEmptyMVar
        io someMVar
        i <- readMVar someMVar
        putMVar serverDone ()
        if i == 5
          then return ()
          else error "Something went horribly wrong"
    putMVar serverAddr addr

  forkIO $ do
    node <- newLocalNode testTransport rtable
    theirAddr <- readMVar serverAddr
    runProcess node $ send theirAddr (putIntClosure 5)

  takeMVar serverDone

testSendProcClosure :: TestTransport -> RemoteTable -> Assertion
testSendProcClosure TestTransport{..} rtable = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    addr <- forkProcess node $ do
      cl <- expect
      pr <- unClosure cl :: Process (Int -> Process ())
      pr 5
    putMVar serverAddr addr

  forkIO $ do
    node <- newLocalNode testTransport rtable
    theirAddr <- readMVar serverAddr
    runProcess node $ do
      pid <- getSelfPid
      send theirAddr (cpSend $(mkStatic 'sdictInt) pid)
      i <- expect :: Process Int
      if i == 5
        then liftIO $ putMVar clientDone ()
        else error "Something went horribly wrong"

  takeMVar clientDone

testSpawn :: TestTransport -> RemoteTable -> Assertion
testSpawn TestTransport{..} rtable = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode testTransport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      pid   <- getSelfPid
      pid'  <- spawn nid (sendPidClosure pid)
      pid'' <- expect
      if pid' == pid''
        then liftIO $ putMVar clientDone ()
        else error "Something went horribly wrong"

  takeMVar clientDone

-- | Tests that spawn executes the supplied closure even if the caller dies
-- immediately after calling spawn.
--
-- This situation is of interest because the implementation of spawn has the
-- remote peer monitor the caller. See DP-99.
--
-- The condition is tested by using a transport which refuses to send to the
-- remote peer the message that it is waiting to stop monitoring the caller,
-- namely @()@.
--
testSpawnRace :: TestTransport -> RemoteTable -> Assertion
testSpawnRace TestTransport{..} rtable = do
    node1 <- newLocalNode (wrapTransport testTransport) rtable
    node2 <- newLocalNode testTransport rtable

    runProcess node1 $ do
      pid <- getSelfPid
      spawnLocal $ spawn (localNodeId node2) (sendPidClosure pid) >>= send pid
      pid'  <- expect :: Process ProcessId
      pid'' <- expect :: Process ProcessId
      if pid' == pid''
        then return ()
        else error "Something went horribly wrong"

  where

    wrapTransport (NT.Transport ne ct) = NT.Transport (fmap (fmap wrapEP) ne) ct

    wrapEP :: NT.EndPoint -> NT.EndPoint
    wrapEP e =
      e { NT.connect = \x y z -> do
            healthy <- newIORef True
            fmap (fmap $ wrapConnection healthy e x) $ NT.connect e x y z
        }

    wrapConnection :: IORef Bool -> NT.EndPoint -> NT.EndPointAddress
                   -> NT.Connection -> NT.Connection
    wrapConnection healthy e remoteAddr (NT.Connection s closeC) =
      flip NT.Connection closeC $ \msg -> do
        when (msg == messageToPayload (createMessage ())) $ do
          writeIORef healthy False
          testBreakConnection (NT.address e) remoteAddr
        isHealthy <- readIORef healthy
        if isHealthy then s msg
          else return $ Left $ NT.TransportError NT.SendFailed ""

testCall :: TestTransport -> RemoteTable -> Assertion
testCall TestTransport{..} rtable = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode testTransport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      (a :: Int) <- call $(mkStatic 'sdictInt) nid (factorialClosure 5)
      if a == 120
        then liftIO $ putMVar clientDone ()
        else error "something went horribly wrong"

  takeMVar clientDone

testCallBind :: TestTransport -> RemoteTable -> Assertion
testCallBind TestTransport{..} rtable = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode testTransport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      (a :: Int) <- call $(mkStatic 'sdictInt) nid (factorial' 5)
      if a == 120
        then liftIO $ putMVar clientDone ()
        else error "Something went horribly wrong"

  takeMVar clientDone

testSeq :: TestTransport -> RemoteTable -> Assertion
testSeq TestTransport{..} rtable = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node $ do
    us <- getSelfPid
    join . unClosure $ sendFac 5 us `seqCP` sendFac 6 us
    a :: Int <- expect
    b :: Int <- expect
    if a == 120 && b == 720
      then liftIO $ putMVar done ()
      else error "Something went horribly wrong"
  takeMVar done

-- Test 'spawnSupervised'
--
-- Set up a supervisor, spawn a child, then have a third process monitor the
-- child. The supervisor then throws an exception, the child dies because it
-- was linked to the supervisor, and the third process notices that the child
-- dies.
testSpawnSupervised :: TestTransport -> RemoteTable -> Assertion
testSpawnSupervised TestTransport{..} rtable = do
    [node1, node2]       <- replicateM 2 $ newLocalNode testTransport rtable
    [superPid, childPid] <- replicateM 2 $ newEmptyMVar
    thirdProcessDone     <- newEmptyMVar
    linkUp               <- newEmptyMVar

    forkProcess node1 $ do
      us <- getSelfPid
      liftIO $ putMVar superPid us
      (child, _ref) <- spawnSupervised (localNodeId node2)
                                       (sendPidClosure us `seqCP` $(mkStaticClosure 'expectUnit))
      _ <- expect :: Process ProcessId

      liftIO $ do putMVar childPid child
                  -- Give the child a chance to link to us
                  takeMVar linkUp
      throw supervisorDeath

    forkProcess node2 $ do
      res <- liftIO $ mapM readMVar [superPid, childPid]
      case res of
        [super, child] -> do
          ref <- monitor child
          self <- getSelfPid
          let waitForMOrL = do
                liftIO $ threadDelay 10000
                mpinfo <- getProcessInfo child
                case mpinfo of
                  Nothing -> waitForMOrL
                  Just pinfo ->
                     unless (isJust $ lookup self (infoMonitors pinfo)) waitForMOrL
          waitForMOrL
          liftIO $ putMVar linkUp ()
          -- because monitor message was sent before message to process
          -- we hope that it will be processed before
          res' <- expect
          case res' of
              (ProcessMonitorNotification ref' pid' (DiedException e)) ->
                if (ref' == ref && pid' == child &&
                  e == show (ProcessLinkException super
                            (DiedException (show supervisorDeath))))
                  then liftIO $ putMVar thirdProcessDone ()
                  else error "Something went horribly wrong"
              _ -> error "Something went horribly wrong"

        _ -> die $ "Something went horribly wrong"

    takeMVar thirdProcessDone
  where
    supervisorDeath :: IOException
    supervisorDeath = userError "Supervisor died"

testSpawnInvalid :: TestTransport -> RemoteTable -> Assertion
testSpawnInvalid TestTransport{..} rtable = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  forkProcess node $ do
    (pid, ref) <- spawnMonitor (localNodeId node) (closure (staticLabel "ThisDoesNotExist") empty)
    ProcessMonitorNotification ref' pid' _reason <- expect
    -- Depending on the exact interleaving, reason might be NoProc or the exception thrown by the absence of the static closure
    res <- return $ ref' == ref && pid == pid'
    if res == True
      then liftIO $ putMVar done ()
      else error "Something went horribly wrong"
  takeMVar done

testClosureExpect :: TestTransport -> RemoteTable -> Assertion
testClosureExpect TestTransport{..} rtable = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node $ do
    nodeId <- getSelfNode
    us     <- getSelfPid
    them   <- spawn nodeId $ cpExpect $(mkStatic 'sdictInt) `bindCP` cpSend $(mkStatic 'sdictInt) us
    send them (1234 :: Int)
    (res :: Int) <- expect
    if res == 1234
      then liftIO $ putMVar done ()
      else error "Something went horribly wrong"
  takeMVar done

testSpawnChannel :: TestTransport -> RemoteTable -> Assertion
testSpawnChannel TestTransport{..} rtable = do
  done <- newEmptyMVar
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport rtable

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

testTDict :: TestTransport -> RemoteTable -> Assertion
testTDict TestTransport{..} rtable = do
  done <- newEmptyMVar
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport rtable
  forkProcess node1 $ do
    res <- call $(functionTDict 'isPrime) (localNodeId node2) ($(mkClosure 'isPrime) (79 :: Integer))
    if res == True
      then liftIO $ putMVar done ()
      else error "Something went horribly wrong..."
  takeMVar done

testFib :: TestTransport -> RemoteTable -> Assertion
testFib TestTransport{..} rtable = do
  nodes <- replicateM 4 $ newLocalNode testTransport rtable
  done <- newEmptyMVar

  forkProcess (head nodes) $ do
    (sport, rport) <- newChan
    spawnLocal $ dfib (map localNodeId nodes, sport, 10)
    ff <- receiveChan rport :: Process Integer
    liftIO $ putMVar done ()
    if ff /= 55
      then die $ "Something went horribly wrong"
      else return ()

  takeMVar done

testSpawnReconnect :: TestTransport -> RemoteTable -> Assertion
testSpawnReconnect testtrans@TestTransport{..} rtable = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport rtable
  let nid1 = localNodeId node1
      -- nid2 = localNodeId node2
  done <- newEmptyMVar
  iv <- newMVar (0 :: Int)

  incr <- forkProcess node1 $ forever $ do
    () <- expect
    liftIO $ modifyMVar_ iv (return . (+ 1))

  forkProcess node2 $ do
    _pid1 <- spawn nid1 ($(mkClosure 'signal) incr)
    simulateNetworkFailure testtrans node2 node1
    _pid2 <- spawn nid1 ($(mkClosure 'signal) incr)
    _pid3 <- spawn nid1 ($(mkClosure 'signal) incr)

    liftIO $ threadDelay 100000

    count <- liftIO $ takeMVar iv
    res <- return $ count == 2 || count == 3 -- It depends on which message we get first in 'spawn'

    liftIO $ putMVar done ()
    if res /= True
      then error "Something went horribly wrong"
      else return ()

  takeMVar done

-- | 'spawn' used to ave a race condition which would be triggered if the
-- spawning process terminates immediately after spawning
testSpawnTerminate :: TestTransport -> RemoteTable -> Assertion
testSpawnTerminate TestTransport{..} rtable = do
  slave  <- newLocalNode testTransport rtable
  master <- newLocalNode testTransport rtable
  masterDone <- newEmptyMVar

  runProcess master $ do
    us <- getSelfPid
    replicateM_ 1000 . spawnLocal . void . spawn (localNodeId slave) $ $(mkClosure 'signal) us
    replicateM_ 1000 $ (expect :: Process ())
    liftIO $ putMVar masterDone ()

  takeMVar masterDone

tests :: TestTransport -> IO [Test]
tests testtrans = do
    let rtable = __remoteTable . __remoteTableDecl $ initRemoteTable
    return
        [ testCase "Unclosure"       (testUnclosure       testtrans rtable)
        , testCase "Bind"            (testBind            testtrans rtable)
        , testCase "SendPureClosure" (testSendPureClosure testtrans rtable)
        , testCase "SendIOClosure"   (testSendIOClosure   testtrans rtable)
        , testCase "SendProcClosure" (testSendProcClosure testtrans rtable)
        , testCase "Spawn"           (testSpawn           testtrans rtable)
        , testCase "SpawnRace"       (testSpawnRace       testtrans rtable)
        , testCase "Call"            (testCall            testtrans rtable)
        , testCase "CallBind"        (testCallBind        testtrans rtable)
        , testCase "Seq"             (testSeq             testtrans rtable)
        , testCase "SpawnSupervised" (testSpawnSupervised testtrans rtable)
        , testCase "SpawnInvalid"    (testSpawnInvalid    testtrans rtable)
        , testCase "ClosureExpect"   (testClosureExpect   testtrans rtable)
        , testCase "SpawnChannel"    (testSpawnChannel    testtrans rtable)
        , testCase "TDict"           (testTDict           testtrans rtable)
        , testCase "Fib"             (testFib             testtrans rtable)
        , testCase "SpawnTerminate"  (testSpawnTerminate  testtrans rtable)
        , testCase "SpawnReconnect"  (testSpawnReconnect  testtrans rtable)
        ]
