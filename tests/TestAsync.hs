{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE ScopedTypeVariables       #-}

module Main where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Async
import Control.Distributed.Process.Tests.Internal.Utils
import Control.Monad (replicateM_)
import Data.Binary()
import Data.Typeable()
import Network.Transport.TCP
import qualified Network.Transport as NT

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.Framework (Test, testGroup, defaultMain)
import Test.Framework.Providers.HUnit (testCase)
-- import TestUtils

testAsyncPoll :: TestResult (AsyncResult ()) -> Process ()
testAsyncPoll result = do
    hAsync <- async $ task $ do "go" <- expect; say "running" >> return ()
    ar <- poll hAsync
    case ar of
      AsyncPending ->
        send (asyncWorker hAsync) "go" >> wait hAsync >>= stash result
      _ -> stash result ar >> return ()

-- Tests that an async action can be canceled.
testAsyncCancel :: TestResult (AsyncResult ()) -> Process ()
testAsyncCancel result = do
    hAsync <- async $ task (expect :: Process ())

    p <- poll hAsync
    case p of
        AsyncPending -> cancel hAsync >> wait hAsync >>= stash result
        _            -> say (show p) >> stash result p

-- Tests that cancelWait completes when the worker dies.
testAsyncCancelWait :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncCancelWait result = do
    hAsync <- async $ task (expect :: Process ())

    AsyncPending <- poll hAsync
    cancelWait hAsync >>= stash result . Just

-- Tests that waitTimeout completes when the timeout expires.
testAsyncWaitTimeout :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncWaitTimeout result = do
    hAsync <- async $ task (expect :: Process ())
    waitTimeout 100000 hAsync >>= stash result
    cancelWait hAsync >> return ()

-- Tests that an async action can be awaited to completion even with a timeout.
testAsyncWaitTimeoutCompletes :: TestResult (Maybe (AsyncResult ()))
                                 -> Process ()
testAsyncWaitTimeoutCompletes result = do
    hAsync <- async $ task (expect :: Process ())
    r <- waitTimeout 100000 hAsync
    case r of
        Nothing -> send (asyncWorker hAsync) ()
                    >> wait hAsync >>= stash result . Just
        Just _  -> cancelWait hAsync >> stash result Nothing

-- Tests that a linked async action dies when the parent dies.
testAsyncLinked :: TestResult Bool -> Process ()
testAsyncLinked result = do
    mv :: MVar (Async ()) <- liftIO newEmptyMVar
    pid <- spawnLocal $ do
        -- NB: async == asyncLinked for AsyncChan
        h <- asyncLinked $ task (expect :: Process ())
        stash mv h
        expect

    hAsync <- liftIO $ takeMVar mv

    mref <- monitorAsync hAsync
    exit pid "stop"

    _ <- receiveWait [
              matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                      (\_ -> return ())
            ]

    -- since the initial caller died and we used 'asyncLinked', the async should
    -- pick up on the exit signal and set the result accordingly. trying to match
    -- on 'DiedException String' is pointless though, as the *string* is highly
    -- context dependent.
    r <- wait hAsync
    case r of
      AsyncLinkFailed _ -> stash result True
      _                 -> stash result False

-- Tests that waitAny returns when any of the actions complete.
testAsyncWaitAny :: TestResult [AsyncResult String] -> Process ()
testAsyncWaitAny result = do
  p1 <- async $ task expect
  p2 <- async $ task expect
  p3 <- async $ task expect
  send (asyncWorker p3) "c"
  r1 <- waitAny [p1, p2, p3]

  send (asyncWorker p1) "a"
  send (asyncWorker p2) "b"
  ref1 <- monitorAsync p1
  ref2 <- monitorAsync p2
  replicateM_ 2 $ receiveWait
    [ matchIf (\(ProcessMonitorNotification ref _ _) -> elem ref [ref1, ref2])
              $ \_ -> return ()
    ]

  r2 <- waitAny [p2, p3]
  r3 <- waitAny [p1, p2, p3]

  stash result $ map snd [r1, r2, r3]

-- Tests that waitAnyTimeout returns when the timeout expires.
testAsyncWaitAnyTimeout :: TestResult (Maybe (AsyncResult String)) -> Process ()
testAsyncWaitAnyTimeout result = do
  p1 <- asyncLinked $ task expect
  p2 <- asyncLinked $ task expect
  p3 <- asyncLinked $ task expect
  waitAnyTimeout 100000 [p1, p2, p3] >>= stash result

-- Tests that cancelWith terminates the worker with the given reason.
testAsyncCancelWith :: TestResult Bool -> Process ()
testAsyncCancelWith result = do
  p1 <- async $ task $ do { s :: String <- expect; return s }
  cancelWith "foo" p1
  AsyncFailed (DiedException _) <- wait p1
  stash result True

-- Tests that waitCancelTimeout returns when the timeout expires.
testAsyncWaitCancelTimeout :: TestResult (AsyncResult ()) -> Process ()
testAsyncWaitCancelTimeout result = do
     p1 <- async $ task expect
     waitCancelTimeout 1000000 p1 >>= stash result

remotableDecl [
    [d| fib :: (NodeId,Int) -> Process Integer ;
        fib (_,0) = return 0
        fib (_,1) = return 1
        fib (myNode,n) = do
          let tsk = remoteTask ($(functionTDict 'fib)) myNode ($(mkClosure 'fib) (myNode,n-2))
          future <- async tsk
          y <- fib (myNode,n-1)
          (AsyncDone z) <- wait future
          return $ y + z
      |]
  ]

-- Tests that wait returns when remote actions complete.
testAsyncRecursive :: TestResult Integer -> Process ()
testAsyncRecursive result = do
    myNode <- getSelfNode
    fib (myNode,6) >>= stash result

tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Handling async results with STM" [
          testCase "testAsyncCancel"
            (delayedAssertion
             "expected async task to have been cancelled"
             localNode (AsyncCancelled) testAsyncCancel)
        , testCase "testAsyncPoll"
            (delayedAssertion
             "expected poll to return a valid AsyncResult"
             localNode (AsyncDone ()) testAsyncPoll)
        , testCase "testAsyncCancelWait"
            (delayedAssertion
             "expected cancelWait to complete some time"
             localNode (Just AsyncCancelled) testAsyncCancelWait)
        , testCase "testAsyncWaitTimeout"
            (delayedAssertion
             "expected waitTimeout to return Nothing when it times out"
             localNode (Nothing) testAsyncWaitTimeout)
        , testCase "testAsyncWaitTimeoutCompletes"
            (delayedAssertion
             "expected waitTimeout to return a value"
             localNode (Just (AsyncDone ())) testAsyncWaitTimeoutCompletes)
        , testCase "testAsyncLinked"
            (delayedAssertion
             "expected linked process to die with originator"
             localNode True testAsyncLinked)
        , testCase "testAsyncWaitAny"
            (delayedAssertion
             "expected waitAny to pick the first result each time"
             localNode [AsyncDone "c",
                        AsyncDone "b",
                        AsyncDone "a"] testAsyncWaitAny)
        , testCase "testAsyncWaitAnyTimeout"
            (delayedAssertion
             "expected waitAnyTimeout to handle pending results properly"
             localNode Nothing testAsyncWaitAnyTimeout)
        , testCase "testAsyncCancelWith"
            (delayedAssertion
             "expected the worker to have been killed with the given signal"
             localNode True testAsyncCancelWith)
        , testCase "testAsyncRecursive"
            (delayedAssertion
             "expected Fibonacci 6 to be evaluated, and value of 8 returned"
             localNode 8 testAsyncRecursive)
        , testCase "testAsyncWaitCancelTimeout"
            (delayedAssertion
             "expected waitCancelTimeout to return a value"
             localNode AsyncCancelled testAsyncWaitCancelTimeout)
      ]
  ]

asyncStmTests :: NT.Transport -> IO [Test]
asyncStmTests transport = do
  localNode <- newLocalNode transport $ __remoteTableDecl initRemoteTable
  let testData = tests localNode
  return testData

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals"127.0.0.1" "0" (\sn -> ("127.0.0.1", sn)) defaultTCPParameters
  testData <- builder transport
  defaultMain testData

main :: IO ()
main = testMain $ asyncStmTests
