{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestUtils
  ( TestResult
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
  -- logging
  , Logger()
  , newLogger
  , putLogMsg
  , stopLogger
  -- runners
  , tryRunProcess
  , testMain
  ) where

import Prelude hiding (catch)
import Control.Concurrent
  ( ThreadId
  , myThreadId
  , forkIO
  )
import Control.Concurrent.STM
  ( TQueue
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , takeMVar
  )
import Control.Exception
import Control.Monad (forever)
import Control.Monad.STM (atomically)

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

-- synchronised logging

data Logger = Logger { _tid :: ThreadId, msgs :: TQueue String }

-- | Create a new Logger.
-- Logger uses a 'TQueue' to receive and process messages on a worker thread.
newLogger :: IO Logger
newLogger = do
  tid <- liftIO $ myThreadId
  q <- liftIO $ newTQueueIO
  forkIO $ logger q
  return $ Logger tid q
  where logger q' = forever $ do
        msg <- atomically $ readTQueue q'
        putStrLn msg

-- | Send a message to the Logger
putLogMsg :: Logger -> String -> Process ()
putLogMsg logger msg = liftIO $ atomically $ writeTQueue (msgs logger) msg

-- | Stop the worker thread for the given Logger
stopLogger :: Logger -> IO ()
stopLogger = (flip throwTo) ThreadKilled . _tid

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                    "127.0.0.1" "8080" defaultTCPParameters
  testData <- builder transport
  defaultMain testData
