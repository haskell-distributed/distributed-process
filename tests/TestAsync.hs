{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestAsync where

import Prelude hiding (catch)
import Data.Binary()
import Data.Typeable()
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP (TransportInternals)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Platform
import Control.Distributed.Platform.Async

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)

import TestUtils

testAsyncPoll :: TestResult (AsyncResult ()) -> Process ()
testAsyncPoll result = do
    hAsync <- async $ runTestProcess $ say "task is running" >> return ()
    ar <- poll hAsync
    case ar of
      AsyncPending ->
        testProcessGo (worker hAsync) >> wait hAsync >>= stash result
      _ -> stash result ar >> return ()

testAsyncCancel :: TestResult (AsyncResult ()) -> Process ()
testAsyncCancel result = do
    hAsync <- async $ runTestProcess $ say "task is running" >> return ()
    sleep $ milliseconds 100
    
    p <- poll hAsync -- nasty kind of assertion: use assertEquals?
    case p of
        AsyncPending -> cancel hAsync >> wait hAsync >>= \x -> do say (show x); stash result x
        _            -> say (show p) >> stash result p
      
tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Handling async results" [
--        testCase "testAsyncPoll"
--            (delayedAssertion
--             "expected poll to return something useful"
--             localNode (AsyncDone ()) testAsyncPoll)
        testCase "testAsyncCancel"
            (delayedAssertion
             "expected async task to have been cancelled"
             localNode (AsyncCancelled) testAsyncCancel)
      ]
  ]

asyncTests :: NT.Transport -> TransportInternals -> IO [Test]
asyncTests transport _ = do
  localNode <- newLocalNode transport initRemoteTable
  let testData = tests localNode
  return testData

