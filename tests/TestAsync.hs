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
import Control.Distributed.Process.Extras (Routable(..), Resolvable(..))
import Control.Distributed.Process.SysTest.Utils
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Timer
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
        sendTo hAsync "go" >> wait hAsync >>= stash result
      _ -> stash result ar >> return ()

testAsyncCancel :: TestResult (AsyncResult ()) -> Process ()
testAsyncCancel result = do
    hAsync <- async $ task $ runTestProcess $ say "running" >> return ()
    sleep $ milliSeconds 100

    p <- poll hAsync -- nasty kind of assertion: use assertEquals?
    case p of
        AsyncPending -> cancel hAsync >> wait hAsync >>= stash result
        _            -> say (show p) >> stash result p

testAsyncCancelWait :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncCancelWait result = do
    testPid <- getSelfPid
    p <- spawnLocal $ do
      hAsync <- async $ task $ runTestProcess $ sleep $ seconds 60
      sleep $ milliSeconds 100

      send testPid "running"

      AsyncPending <- poll hAsync
      cancelWait hAsync >>= send testPid

    "running" <- expect
    d <- expectTimeout (asTimeout $ seconds 5)
    case d of
        Nothing -> kill p "timed out" >> stash result Nothing
        Just ar -> stash result (Just ar)

testAsyncWaitTimeout :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncWaitTimeout result =
    let delay = seconds 1
    in do
    hAsync <- async $ task $ sleep $ seconds 20
    waitTimeout delay hAsync >>= stash result
    cancelWait hAsync >> return ()

testAsyncWaitTimeoutCompletes :: TestResult (Maybe (AsyncResult ()))
                              -> Process ()
testAsyncWaitTimeoutCompletes result =
    let delay = seconds 1
    in do
    hAsync <- async $ task $ sleep $ seconds 20
    waitTimeout delay hAsync >>= stash result
    cancelWait hAsync >> return ()

testAsyncWaitTimeoutSTM :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncWaitTimeoutSTM result =
    let delay = seconds 1
    in do
    hAsync <- async $ task $ sleep $ seconds 20
    waitTimeoutSTM delay hAsync >>= stash result

testAsyncWaitTimeoutCompletesSTM :: TestResult (Maybe (AsyncResult Int))
                                 -> Process ()
testAsyncWaitTimeoutCompletesSTM result =
    let delay = seconds 1 in do

    hAsync <- async $ task $ do
        i <- expect
        return i

    r <- waitTimeoutSTM delay hAsync
    case r of
        Nothing -> sendTo hAsync (10 :: Int)
                    >> wait hAsync >>= stash result . Just
        Just _  -> cancelWait hAsync >> stash result Nothing

testAsyncLinked :: TestResult Bool -> Process ()
testAsyncLinked result = do
    mv :: MVar (Async ()) <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
        -- NB: async == asyncLinked for AsyncChan
        h <- asyncLinked $ task $ do
            "waiting" <- expect
            return ()
        stash mv h
        "sleeping" <- expect
        return ()

    hAsync <- liftIO $ takeMVar mv

    Just worker <- resolve hAsync
    mref <- monitor worker
    exit pid "stop"

    _ <- receiveTimeout (after 5 Seconds) [
              matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                      (\_ -> return ())
            ]

    -- since the initial caller died and we used 'asyncLinked', the async should
    -- pick up on the exit signal and set the result accordingly. trying to match
    -- on 'DiedException String' is pointless though, as the *string* is highly
    -- context dependent.
    r <- waitTimeoutSTM (within 3 Seconds) hAsync
    case r of
        Nothing -> stash result True
        Just _  -> stash result False

testAsyncWaitAny :: TestResult [AsyncResult String] -> Process ()
testAsyncWaitAny result = do
  p1 <- async $ task $ expect >>= return
  p2 <- async $ task $ expect >>= return
  p3 <- async $ task $ expect >>= return
  sendTo p3 "c"
  r1 <- waitAny [p1, p2, p3]

  sendTo p1 "a"
  sendTo p2 "b"
  sleep $ seconds 1

  r2 <- waitAny [p2, p3]
  r3 <- waitAny [p1, p2, p3]

  stash result $ map snd [r1, r2, r3]

testAsyncWaitAnyTimeout :: TestResult (Maybe (AsyncResult String)) -> Process ()
testAsyncWaitAnyTimeout result = do
  p1 <- asyncLinked $ task $ expect >>= return
  p2 <- asyncLinked $ task $ expect >>= return
  p3 <- asyncLinked $ task $ expect >>= return
  waitAnyTimeout (seconds 1) [p1, p2, p3] >>= stash result

testAsyncCancelWith :: TestResult Bool -> Process ()
testAsyncCancelWith result = do
  p1 <- async $ task $ do { s :: String <- expect; return s }
  cancelWith "foo" p1
  AsyncFailed (DiedException _) <- wait p1
  stash result True

testAsyncWaitCancelTimeout :: TestResult (AsyncResult ()) -> Process ()
testAsyncWaitCancelTimeout result = do
     p1 <- async $ task $ sleep $ seconds 20
     waitCancelTimeout (seconds 1) p1 >>= stash result

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
testAsyncRecursive :: TestResult Integer -> Process ()
testAsyncRecursive result = do
    myNode <- processNodeId <$> getSelfPid
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
        , testCase "testAsyncWaitTimeoutSTM"
            (delayedAssertion
             "expected waitTimeoutSTM to return Nothing when it times out"
             localNode (Nothing) testAsyncWaitTimeoutSTM)
        , testCase "testAsyncWaitTimeoutCompletes"
            (delayedAssertion
             "expected waitTimeout to return a value"
             localNode Nothing testAsyncWaitTimeoutCompletes)
        , testCase "testAsyncWaitTimeoutCompletesSTM"
            (delayedAssertion
             "expected waitTimeout to return a value"
             localNode (Just (AsyncDone 10)) testAsyncWaitTimeoutCompletesSTM)
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
  Right (transport, _) <- createTransportExposeInternals
                                     "127.0.0.1" "0" defaultTCPParameters
  testData <- builder transport
  defaultMain testData

main :: IO ()
main = testMain $ asyncStmTests
