{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE CPP                #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Test
-- Copyright   :  (c) Tim Watson, Jeff Epstein 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides basic building blocks for testing Cloud Haskell programs.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Test
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
  -- runners
  , tryRunProcess
  , tryForkProcess
  ) where

import Control.Concurrent
  ( myThreadId
  , throwTo
  )
import Control.Concurrent.MVar
  ( MVar
  , putMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Exception (SomeException)
import Control.Monad (forever)
import Data.Binary
import Data.Typeable (Typeable)
#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

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

-- | Starts a test process on the local node.
startTestProcess :: Process () -> Process ProcessId
startTestProcess proc = spawnLocal $ runTestProcess proc

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
testProcessGo pid = (say $ (show pid) ++ " go!") >> send pid Go

-- | Tell a /test process/ to stop (i.e., 'terminate')
testProcessStop :: ProcessId -> Process ()
testProcessStop pid = send pid Stop

-- | Tell a /test process/ to send a report (message)
-- back to the calling process
testProcessReport :: ProcessId -> Process ()
testProcessReport pid = do
  self <- getSelfPid
  send pid $ Report self

-- | Does exactly what it says on the tin, doing so in the @Process@ monad.
noop :: Process ()
noop = return ()

-- | Stashes a value in our 'TestResult' using @putMVar@
stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

tryRunProcess :: LocalNode -> Process () -> IO ()
tryRunProcess node p = do
  tid <- liftIO myThreadId
  runProcess node $ catch p (\e -> liftIO $ throwTo tid (e::SomeException))

tryForkProcess :: LocalNode -> Process () -> IO ProcessId
tryForkProcess node p = do
  tid <- liftIO myThreadId
  forkProcess node $ catch p (\e -> liftIO $ throwTo tid (e::SomeException))
