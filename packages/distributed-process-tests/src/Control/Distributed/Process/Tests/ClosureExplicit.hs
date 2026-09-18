module Control.Distributed.Process.Tests.ClosureExplicit (tests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Distributed.Process
  ( Closure,
    Process,
    ProcessId,
    RemoteTable,
    Static,
    expect,
    getSelfPid,
    liftIO,
    send,
    spawn,
    unClosure,
    unStatic,
  )
import Control.Distributed.Process.Closure
  ( RemoteRegister,
    call',
    mkClosureVal,
    mkClosureValSingle,
    mkStaticVal,
  )
import Control.Distributed.Process.Node
  ( LocalNode (localNodeId),
    initRemoteTable,
    newLocalNode,
    runProcess,
  )
import Control.Monad (replicateM)
import Network.Transport.Test (TestTransport (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, testCase, (@?=))

tests :: TestTransport -> IO TestTree
tests testtrans =
  return $
    testGroup
      "ClosureExplicit"
      [ testCase "MkStaticVal" (testMkStaticVal testtrans),
        testCase "UnClosure" (testUnClosure testtrans),
        testCase "SpawnSingle" (testSpawnSingle testtrans),
        testCase "SpawnMultiArg" (testSpawnMultiArg testtrans),
        testCase "CallSingle" (testCallSingle testtrans),
        testCase "CallMultiArg" (testCallMultiArg testtrans)
      ]

testMkStaticVal :: TestTransport -> Assertion
testMkStaticVal TestTransport {..} = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node $ unStatic staticAnswer >>= liftIO . putMVar done
  takeMVar done >>= (@?= answer)

testUnClosure :: TestTransport -> Assertion
testUnClosure TestTransport {..} = do
  node <- newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node $ unClosure (addIntClosure 17 25) >>= liftIO . putMVar done
  takeMVar done >>= (@?= answer)

testSpawnSingle :: TestTransport -> Assertion
testSpawnSingle TestTransport {..} = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode testTransport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      us <- getSelfPid
      them <- spawn nid (echoPidClosure us)
      them' <- expect
      liftIO $ putMVar clientDone (them == them')

  takeMVar clientDone >>= (@?= True)

testSpawnMultiArg :: TestTransport -> Assertion
testSpawnMultiArg TestTransport {..} = do
  serverNodeAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    node <- newLocalNode testTransport rtable
    putMVar serverNodeAddr (localNodeId node)

  forkIO $ do
    node <- newLocalNode testTransport rtable
    nid <- readMVar serverNodeAddr
    runProcess node $ do
      us <- getSelfPid
      _ <- spawn nid (sendSumClosure 41 us)
      n <- expect
      liftIO $ putMVar clientDone (n :: Int)

  takeMVar clientDone >>= (@?= answer)

testCallSingle :: TestTransport -> Assertion
testCallSingle TestTransport {..} = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node1 $
    call' (localNodeId node2) (factorialClosure 5) >>= liftIO . putMVar done
  takeMVar done >>= (@?= (120 :: Int))

testCallMultiArg :: TestTransport -> Assertion
testCallMultiArg TestTransport {..} = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport rtable
  done <- newEmptyMVar
  runProcess node1 $
    call' (localNodeId node2) (sendProductClosure 2 3 7) >>= liftIO . putMVar done
  takeMVar done >>= (@?= (42 :: Int))

staticAnswer :: Static Int
answerRegister :: RemoteRegister
(staticAnswer, answerRegister) = mkStaticVal "answer" answer

echoPidClosure :: ProcessId -> Closure (Process ())
echoPidRegister :: RemoteRegister
(echoPidClosure, echoPidRegister) = mkClosureValSingle "echoPid" echoPid

factorialClosure :: Int -> Closure (Process Int)
factorialRegister :: RemoteRegister
(factorialClosure, factorialRegister) = mkClosureValSingle "factorial" factorial

sendSumClosure :: Int -> ProcessId -> Closure (Process ())
sendSumRegister :: RemoteRegister
(sendSumClosure, sendSumRegister) = mkClosureVal "sendSum" sendSum

sendProductClosure :: Int -> Int -> Int -> Closure (Process Int)
sendProductRegister :: RemoteRegister
(sendProductClosure, sendProductRegister) = mkClosureVal "sendProduct" sendProduct

addIntClosure :: Int -> Int -> Closure Int
addIntRegister :: RemoteRegister
(addIntClosure, addIntRegister) = mkClosureVal "addInt" addInt

rtable :: RemoteTable
rtable =
  answerRegister
    . echoPidRegister
    . factorialRegister
    . sendSumRegister
    . sendProductRegister
    . addIntRegister
    $ initRemoteTable

echoPid :: ProcessId -> Process ()
echoPid them = getSelfPid >>= send them

sendSum :: Int -> ProcessId -> Process ()
sendSum n them = send them (n + 1 :: Int)

sendProduct :: Int -> Int -> Int -> Process Int
sendProduct x y z = return (x * y * z)

factorial :: Int -> Process Int
factorial n = return (product [1 .. n])

addInt :: Int -> Int -> Int
addInt = (+)

answer :: Int
answer = 42
