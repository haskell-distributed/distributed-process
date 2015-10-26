{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE CPP                #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Tests.Internal.Utils
-- Copyright   :  (c) Tim Watson, Jeff Epstein 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides basic building blocks for testing Cloud Haskell programs.
-----------------------------------------------------------------------------
module Control.Distributed.Process.Tests.Internal.Utils
  ( TestResult
  -- ping !
  , Ping(Ping)
  , ping
  , shouldBe
  , shouldMatch
  , shouldContain
  , shouldNotContain
  , expectThat
  , synchronisedAssertion
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
  , tryForkProcess
  , noop
  , stash
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif
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

import Control.Concurrent
  ( throwTo
  )
import Control.Concurrent.MVar
  ( putMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()

import Control.Exception (AsyncException(ThreadKilled), SomeException)
import Control.Monad (forever)
import Control.Monad.STM (atomically)
import Control.Rematch hiding (match)
import Control.Rematch.Run 
import Data.Binary
import Data.Typeable (Typeable)

import Test.HUnit (Assertion, assertFailure)
import Test.HUnit.Base (assertBool)

import GHC.Generics

-- | A mutable cell containing a test result.
type TestResult a = MVar a

-- | A simple @Ping@ signal
data Ping = Ping
    deriving (Typeable, Generic, Eq, Show)
instance Binary Ping where

ping :: ProcessId -> Process ()
ping pid = send pid Ping

-- | Control signals used to manage /test processes/
data TestProcessControl = Stop | Go | Report ProcessId
    deriving (Typeable, Generic)

instance Binary TestProcessControl where

-- | Does exactly what it says on the tin, doing so in the @Process@ monad.
noop :: Process ()
noop = return ()

synchronisedAssertion :: Eq a
                      => String
                      -> LocalNode
                      -> a
                      -> (TestResult a -> Process ())
                      -> MVar ()
                      -> Assertion
synchronisedAssertion note localNode expected testProc lock = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ do
         acquire lock
         finally (testProc result)
                 (release lock)
  assertComplete note result expected
  where acquire lock' = liftIO $ takeMVar lock'
        release lock' = liftIO $ putMVar lock' ()

stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

expectThat :: a -> Matcher a -> Process ()
expectThat a matcher = case res of
  MatchSuccess -> return ()
  (MatchFailure msg) -> liftIO $ assertFailure msg
  where res = runMatch matcher a

shouldBe :: a -> Matcher a -> Process ()
shouldBe = expectThat

shouldContain :: (Show a, Eq a) => [a] -> a -> Process ()
shouldContain xs x = expectThat xs $ hasItem (equalTo x)

shouldNotContain :: (Show a, Eq a) => [a] -> a -> Process ()
shouldNotContain xs x = expectThat xs $ isNot (hasItem (equalTo x))

shouldMatch :: a -> Matcher a -> Process ()
shouldMatch = expectThat

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
  _ <- forkIO $ logger q
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

-- | Starts a test process on the local node.
startTestProcess :: Process () -> Process ProcessId
startTestProcess proc =
  spawnLocal $ do
    getSelfPid >>= register "test-process"
    runTestProcess proc

-- | Runs a /test process/ around the supplied @proc@, which is executed
-- whenever the outer process loop receives a 'Go' signal.
runTestProcess :: Process () -> Process ()
runTestProcess proc = do
  ctl <- expect
  case ctl of
    Stop     -> return ()
    Go       -> proc >> runTestProcess proc
    Report p -> receiveWait [matchAny (\m -> forward m p)] >> runTestProcess proc

-- | Tell a /test process/ to continue executing
testProcessGo :: ProcessId -> Process ()
testProcessGo pid = send pid Go

-- | Tell a /test process/ to stop (i.e., 'terminate')
testProcessStop :: ProcessId -> Process ()
testProcessStop pid = send pid Stop

-- | Tell a /test process/ to send a report (message)
-- back to the calling process
testProcessReport :: ProcessId -> Process ()
testProcessReport pid = do
  self <- getSelfPid
  send pid $ Report self

tryRunProcess :: LocalNode -> Process () -> IO ()
tryRunProcess node p = do
  tid <- liftIO myThreadId
  runProcess node $ catch p (\e -> liftIO $ throwTo tid (e::SomeException))

tryForkProcess :: LocalNode -> Process () -> IO ProcessId
tryForkProcess node p = do
  tid <- liftIO myThreadId
  forkProcess node $ catch p (\e -> liftIO $ throwTo tid (e::SomeException))

