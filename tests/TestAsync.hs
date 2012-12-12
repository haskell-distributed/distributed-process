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

testAsyncPoll :: TestResult (AsyncResult Ping) -> Process ()
testAsyncPoll result = do
    hAsync <- async $ say "task is running" >> return Ping
    sleep $ seconds 1
    
    ar <- poll hAsync
    case ar of
      AsyncPending ->
        testProcessGo (worker hAsync) >> wait hAsync >>= stash result
      _ -> stash result ar >> return ()

testAsyncCancel :: TestResult (AsyncResult Int) -> Process ()
testAsyncCancel result = do
    hAsync <- async $ say "task is running" >> return 42
    sleep $ milliseconds 100
    
    AsyncPending <- poll hAsync -- nasty kind of assertion: use assertEquals?
    
    cancel hAsync
    wait hAsync >>= stash result
      
tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Handling async results" [
        testCase "testAsyncPoll"
            (delayedAssertion
             "expected poll to return something useful"
             localNode (AsyncDone Ping) testAsyncPoll)
      , testCase "testAsyncCancel"
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

