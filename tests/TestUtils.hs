{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestUtils
  ( TestResult
  , noop
  , stash
  -- ping !
  , Ping(Ping)
  , ping
  -- test process utilities
  , TestProcessControl
  , startTestProcess
  , runTestProcess
  , testProcessGo
  , testProcessStop
  , testProcessReport
  , delayedAssertion
  , assertComplete
  -- runners
  , tryRunProcess
  , testMain
  ) where

import Prelude hiding (catch)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.Test

import Test.HUnit (Assertion)
import Test.HUnit.Base (assertBool)
import Test.Framework (Test, defaultMain)

import Network.Transport.TCP
import qualified Network.Transport as NT
          
-- | Run the supplied @testProc@ using an @MVar@ to collect and assert
-- against its result. Uses the supplied @note@ if the assertion fails.
delayedAssertion :: (Eq a) => String -> LocalNode -> a ->
                    (TestResult a -> Process ()) -> Assertion
delayedAssertion note localNode expected testProc = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ testProc result
  assertComplete note result expected

-- | Takes the value of @mv@ (using @takeMVar@) and asserts that it matches @a@
assertComplete :: (Eq a) => String -> MVar a -> a -> IO ()
assertComplete msg mv a = do
  b <- takeMVar mv
  assertBool msg (a == b)

testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                    "127.0.0.1" "8080" defaultTCPParameters
  testData <- builder transport
  defaultMain testData 

