{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE ExistentialQuantification   #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Async
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The modules in the @Async@ package provide operations for spawning Processes,
-- waiting for their results, cancelling them and various other utilities. The
-- two primary implementation are @AsyncChan@ which provides an API which is
-- scoped to the calling process, and @Async@ which provides a mechanism that
-- can be used by (i.e., shared across) multiple processes either locally or
-- situation on remote nodes.
--
-- Both abstractions can run asynchronous operations on remote nodes.
--
-- Despite providing an API at a higher level than the basic primitives in
-- distributed-process, this API is still quite low level and it is
-- recommended that you read the documentation carefully to understand its
-- constraints. For a much higher level API, consider using the
-- 'Control.Distributed.Platform.Task' layer.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Async
 ( -- types/data
    Async(asyncWorker)
  , AsyncRef
  , AsyncTask(..)
  , AsyncResult(..)
  -- functions for starting/spawning
  , async
  , asyncLinked
  , asyncSTM
  , asyncDo
  -- and stopping/killing
  , cancel
  , cancelWait
  , cancelWith
  , cancelKill
  -- functions to query an async-result
  , poll
  , check
  , wait
-- , waitAny
-- , waitAnyTimeout
  , waitTimeout
  , waitCheckTimeout
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Platform.Async.Types
  ( Async(..)
  , AsyncRef
  , AsyncTask(..)
  , AsyncResult(..)
  )
import qualified Control.Distributed.Process.Platform.Async.AsyncSTM as AsyncSTM
-- import qualified Control.Distributed.Process.Platform.Async.AsyncChan as AsyncChan
import Control.Distributed.Process.Platform.Time

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

async :: (Serializable a) => Process a -> Process (Async a)
async t = asyncSTM (AsyncTask t)

asyncLinked :: (Serializable a) => Process a -> Process (Async a)
asyncLinked p = AsyncSTM.newAsync AsyncSTM.asyncLinked (AsyncTask p)

asyncSTM :: (Serializable a) => AsyncTask a -> Process (Async a)
asyncSTM = AsyncSTM.newAsync AsyncSTM.async

asyncDo :: Process a -> AsyncTask a
asyncDo = AsyncTask

-- | Check whether an 'AsyncSTM' has completed yet. The status of the
-- action is encoded in the returned 'AsyncResult'. If the action has not
-- completed, the result will be 'AsyncPending', or one of the other
-- constructors otherwise. This function does not block waiting for the result.
-- Use 'wait' or 'waitTimeout' if you need blocking/waiting semantics.
-- See 'Async'.
{-# INLINE poll #-}
poll :: (Serializable a) => Async a -> Process (AsyncResult a)
poll = h_poll

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
-- See 'poll'.
{-# INLINE check #-}
check :: (Serializable a) => Async a -> Process (Maybe (AsyncResult a))
check = h_check

-- | Wait for an asynchronous operation to complete or timeout. This variant
-- returns the 'AsyncResult' itself, which will be 'AsyncPending' if the
-- result has not been made available, otherwise one of the other constructors.
{-# INLINE waitCheckTimeout #-}
waitCheckTimeout :: (Serializable a) =>
                    TimeInterval -> Async a -> Process (AsyncResult a)
waitCheckTimeout = flip h_waitCheckTimeout

-- | Wait for an asynchronous action to complete, and return its
-- value. The result (which can include failure and/or cancellation) is
-- encoded by the 'AsyncResult' type.
--
-- > wait = liftIO . atomically . waitSTM
--
{-# INLINE wait #-}
wait :: Async a -> Process (AsyncResult a)
wait = h_wait

-- | Wait for an asynchronous operation to complete or timeout. Returns
-- @Nothing@ if the 'AsyncResult' does not change from @AsyncPending@ within
-- the specified delay, otherwise @Just asyncResult@ is returned. If you want
-- to wait/block on the 'AsyncResult' without the indirection of @Maybe@ then
-- consider using 'wait' or 'waitCheckTimeout' instead.
{-# INLINE waitTimeout #-}
waitTimeout :: (Serializable a) =>
               TimeInterval -> Async a -> Process (Maybe (AsyncResult a))
waitTimeout = flip h_waitTimeout

-- | Cancel an asynchronous operation. Cancellation is asynchronous in nature.
-- To wait for cancellation to complete, use 'cancelWait' instead. The notes
-- about the asynchronous nature of 'cancelWait' apply here also.
--
-- See 'Control.Distributed.Process'
{-# INLINE cancel #-}
cancel :: Async a -> Process ()
cancel = h_cancel

-- | Cancel an asynchronous operation and wait for the cancellation to complete.
-- Because of the asynchronous nature of message passing, the instruction to
-- cancel will race with the asynchronous worker, so it is /entirely possible/
-- that the 'AsyncResult' returned will not necessarily be 'AsyncCancelled'. For
-- example, the worker may complete its task after this function is called, but
-- before the cancellation instruction is acted upon.
--
-- If you wish to stop an asychronous operation /immediately/ (with caveats)
-- then consider using 'cancelWith' or 'cancelKill' instead.
--
{-# INLINE cancelWait #-}
cancelWait :: (Serializable a) => Async a -> Process (AsyncResult a)
cancelWait = h_cancelWait

-- | Cancel an asynchronous operation immediately.
-- This operation is performed by sending an /exit signal/ to the asynchronous
-- worker, which leads to the following semantics:
--
-- 1. if the worker already completed, this function has no effect
-- 2. the worker might complete after this call, but before the signal arrives
-- 3. the worker might ignore the exit signal using @catchExit@
--
-- In case of (3), this function has no effect. You should use 'cancel'
-- if you need to guarantee that the asynchronous task is unable to ignore
-- the cancellation instruction.
--
-- You should also consider that when sending exit signals to a process, the
-- definition of 'immediately' is somewhat vague and a scheduler might take
-- time to handle the request, which can lead to situations similar to (1) as
-- listed above, if the scheduler to which the calling process' thread is bound
-- decides to GC whilst another scheduler on which the worker is running is able
-- to continue.
--
-- See 'Control.Distributed.Process.exit'
{-# INLINE cancelWith #-}
cancelWith :: (Serializable b) => b -> Async a -> Process ()
cancelWith = flip h_cancelWith

-- | Like 'cancelWith' but sends a @kill@ instruction instead of an exit.
--
-- See 'Control.Distributed.Process.kill'
{-# INLINE cancelKill #-}
cancelKill :: String -> Async a -> Process ()
cancelKill = flip h_cancelKill
