{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestAsync where

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Platform
import Control.Distributed.Platform.Async
import Data.Binary()
import Data.Typeable()
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP (TransportInternals)
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
      ]
  ]

asyncTests :: NT.Transport -> TransportInternals -> IO [Test]
asyncTests transport _ = do
  localNode <- newLocalNode transport initRemoteTable
  let testData = tests localNode
  return testData

