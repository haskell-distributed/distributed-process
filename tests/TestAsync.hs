{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE ScopedTypeVariables       #-}

module Main where

import Control.Concurrent.MVar
  ( newEmptyMVar
  , takeMVar
  , MVar)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Platform
import Control.Distributed.Platform.Async.AsyncChan
import Data.Binary()
import Data.Typeable()
import qualified Network.Transport as NT (Transport)
import Prelude hiding (catch)

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils

testAsyncPoll :: TestResult (AsyncResult ()) -> Process ()
testAsyncPoll result = do
    hAsync <- async $ do "go" <- expect; say "running" >> return ()
    ar <- poll hAsync
    case ar of
      AsyncPending ->
        send (worker hAsync) "go" >> wait hAsync >>= stash result
      _ -> stash result ar >> return ()

testAsyncCancel :: TestResult (AsyncResult ()) -> Process ()
testAsyncCancel result = do
    hAsync <- async $ runTestProcess $ say "running" >> return ()
    sleep $ milliseconds 100
    
    p <- poll hAsync -- nasty kind of assertion: use assertEquals?
    case p of
        AsyncPending -> cancel hAsync >> wait hAsync >>= stash result
        _            -> say (show p) >> stash result p

testAsyncCancelWait :: TestResult (Maybe (AsyncResult ())) -> Process ()
testAsyncCancelWait result = do
    testPid <- getSelfPid
    p <- spawnLocal $ do
      hAsync <- async $ runTestProcess $ say "running" >> (sleep $ seconds 60)
      sleep $ milliseconds 100

      send testPid "running"

      AsyncPending <- poll hAsync
      cancelWait hAsync >>= send testPid
    
    "running" <- expect
    d <- expectTimeout (intervalToMs $ seconds 5)
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

testAsyncLinked :: TestResult Bool -> Process ()
testAsyncLinked result = do
    mv :: MVar (AsyncChan ()) <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
        h <- asyncLinked $ do
            "waiting" <- expect
            return ()
        stash mv h
        "sleeping" <- expect
        return ()
    
    hAsync <- liftIO $ takeMVar mv
    
    mref <- monitor $ worker hAsync
    exit pid "stop"
    
    ProcessMonitorNotification mref' _ _ <- expect
    
    -- since the initial caller died and we used 'asyncLinked', the async should
    -- pick up on the exit signal and set the result accordingly, however the
    -- ReceivePort is no longer valid, so we can't wait on it! We have to ensure
    -- that the worker is really dead then....
    stash result $ mref == mref'

testAsyncWaitAny :: TestResult String -> Process ()
testAsyncWaitAny result = do
  p1 <- async $ expect >>= return
  p2 <- async $ expect >>= return
  p3 <- async $ expect >>= return
  send (worker p3) "c"
  AsyncDone r1 <- waitAny [p1, p2, p3]
  send (worker p1) "a"
  AsyncDone r2 <- waitAny [p1, p2, p3]
  send (worker p2) "b"
  AsyncDone r3 <- waitAny [p1, p2, p3]
  stash result $ foldl (++) "" [r1, r2, r3]

testAsyncWaitAnyTimeout :: TestResult (Maybe (AsyncResult String)) -> Process ()
testAsyncWaitAnyTimeout result = do
  p1 <- asyncLinked $ expect >>= return
  p2 <- asyncLinked $ expect >>= return
  p3 <- asyncLinked $ expect >>= return
  waitAnyTimeout (seconds 1) [p1, p2, p3] >>= stash result

testAsyncCancelWith :: TestResult Bool -> Process ()
testAsyncCancelWith result = do
  p1 <- async $ do { s :: String <- expect; return s }
  cancelWith "foo" p1 
  AsyncFailed (DiedException _) <- wait p1
  stash result True

tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Handling async results" [
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
        , testCase "testAsyncLinked"
            (delayedAssertion
             "expected linked process to die with originator"
             localNode True testAsyncLinked)
        , testCase "testAsyncWaitAny"
            (delayedAssertion
             "expected waitAny to mimic mergePortsBiased"
             localNode "cab" testAsyncWaitAny)
        , testCase "testAsyncWaitAnyTimeout"
            (delayedAssertion
             "expected waitAnyTimeout to handle idle channels properly"
             localNode Nothing testAsyncWaitAnyTimeout)
        , testCase "testAsyncCancelWith"
            (delayedAssertion
             "expected the worker to have been killed with the given signal"
             localNode True testAsyncCancelWith)
      ]
  ]

asyncTests :: NT.Transport -> IO [Test]
asyncTests transport = do
  localNode <- newLocalNode transport initRemoteTable
  let testData = tests localNode
  return testData

main :: IO ()
main = testMain $ asyncTests
