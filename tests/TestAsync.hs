{-# LANGUAGE ScopedTypeVariables       #-}

module Main where

import Control.Concurrent.MVar (MVar, takeMVar, newEmptyMVar)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import qualified Network.Transport as NT
import TestAsyncChan (asyncChanTests)
import TestAsyncSTM (asyncStmTests)
import TestUtils

testAsyncPoll :: TestResult (AsyncResult ()) -> Process ()
testAsyncPoll result = do
    hAsync <- async $ do "go" <- expect; say "running" >> return ()
    ar <- poll hAsync
    case ar of
      AsyncPending ->
        send (asyncWorker hAsync) "go" >> wait hAsync >>= stash result
      _ -> stash result ar >> return ()

testAsyncCancel :: TestResult (AsyncResult ()) -> Process ()
testAsyncCancel result = do
    hAsync <- async $ runTestProcess $ say "running" >> return ()
    sleep $ milliSeconds 100

    p <- poll hAsync -- nasty kind of assertion: use assertEquals?
    case p of
        AsyncPending -> cancel hAsync >> wait hAsync >>= stash result
        _            -> say (show p) >> stash result p

testAsyncCancelWait :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncCancelWait result = do
    testPid <- getSelfPid
    p <- spawnLocal $ do
      hAsync <- async $ runTestProcess $ sleep $ seconds 60
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
    hAsync <- async $ sleep $ seconds 20
    waitTimeout delay hAsync >>= stash result
    cancelWait hAsync >> return ()

testAsyncWaitTimeoutCompletes :: TestResult (Maybe (AsyncResult ()))
                              -> Process ()
testAsyncWaitTimeoutCompletes result =
    let delay = seconds 1
    in do
    hAsync <- async $ sleep $ seconds 20
    waitTimeout delay hAsync >>= stash result
    cancelWait hAsync >> return ()

testAsyncLinked :: TestResult Bool -> Process ()
testAsyncLinked result = do
    mv :: MVar (Async ()) <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
        -- NB: async == asyncLinked for AsyncChan
        h <- asyncLinked $ do
            "waiting" <- expect
            return ()
        stash mv h
        "sleeping" <- expect
        return ()

    hAsync <- liftIO $ takeMVar mv

    mref <- monitor $ asyncWorker hAsync
    exit pid "stop"

    _ <- receiveTimeout (after 5 Seconds) [
              matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                      (\_ -> return ())
            ]

    -- since the initial caller died and we used 'asyncLinked', the async should
    -- pick up on the exit signal and set the result accordingly. trying to match
    -- on 'DiedException String' is pointless though, as the *string* is highly
    -- context dependent.
    r <- waitTimeout (within 3 Seconds) hAsync
    case r of
        Nothing -> stash result True
        Just _  -> stash result False

testAsyncCancelWith :: TestResult Bool -> Process ()
testAsyncCancelWith result = do
  p1 <- async $ do { s :: String <- expect; return s }
  cancelWith "foo" p1
  AsyncFailed (DiedException _) <- wait p1
  stash result True

allAsyncTests :: NT.Transport -> IO [Test]
allAsyncTests transport = do
  chanTestGroup <- asyncChanTests transport
  stmTestGroup  <- asyncStmTests transport
  localNode <- newLocalNode transport initRemoteTable
  return [
       testGroup "Async Channel" chanTestGroup
     , testGroup "Async STM"     stmTestGroup
     , testGroup "Async Common API" [
          testCase "Async Common API cancel"
            (delayedAssertion
             "expected async task to have been cancelled"
             localNode (AsyncCancelled) testAsyncCancel)
        , testCase "Async Common API poll"
            (delayedAssertion
             "expected poll to return a valid AsyncResult"
             localNode (AsyncDone ()) testAsyncPoll)
        , testCase "Async Common API cancelWait"
            (delayedAssertion
             "expected cancelWait to complete some time"
             localNode (Just AsyncCancelled) testAsyncCancelWait)
        , testCase "Async Common API waitTimeout"
            (delayedAssertion
             "expected waitTimeout to return Nothing when it times out"
             localNode (Nothing) testAsyncWaitTimeout)
        , testCase "Async Common API waitTimeout completion"
            (delayedAssertion
             "expected waitTimeout to return a value"
             localNode Nothing testAsyncWaitTimeoutCompletes)
        , testCase "Async Common API asyncLinked"
            (delayedAssertion
             "expected linked process to die with originator"
             localNode True testAsyncLinked)
        , testCase "Async Common API cancelWith"
            (delayedAssertion
             "expected the worker to have been killed with the given signal"
             localNode True testAsyncCancelWith)
     ] ]

main :: IO ()
main = testMain $ allAsyncTests
