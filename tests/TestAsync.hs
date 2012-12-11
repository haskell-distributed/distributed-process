{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestAsync where

import Prelude hiding (catch)
import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.DeriveTH
import Control.Monad (forever)
import Data.Maybe (fromMaybe)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , withMVar
  , tryTakeMVar
  )
-- import Control.Applicative ((<$>), (<*>), pure, (<|>))
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP (TransportInternals)
import Control.Distributed.Process
import Control.Distributed.Platform
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable(Serializable)
import Control.Distributed.Platform.Async
import Control.Distributed.Platform

import Test.HUnit (Assertion)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import Test.HUnit.Base (assertBool)

import TestUtils

testAsyncPoll :: TestResult Bool -> Process ()
testAsyncPoll = do
  self <- getSelfPid
  async $ do
    return ()

tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Async Tests" [
        testCase "testAsyncPoll"
            (delayedAssertion
             "expected poll to return something useful"
             localNode True testAsyncPoll)
      ]
  ]

asyncTests :: NT.Transport -> TransportInternals -> IO [Test]
asyncTests transport _ = do
  localNode <- newLocalNode transport initRemoteTable
  let testData = tests localNode
  return testData

