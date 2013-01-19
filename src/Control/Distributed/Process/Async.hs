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
-- The /async/ APIs provided by distributed-process-platform provide means
-- for spawning asynchronous operations, waiting for their results, cancelling
-- them and various other utilities. The two primary implementation are
-- @AsyncChan@ which provides a handle which is scoped to the calling process,
-- and @AsyncSTM@, whose async mechanism can be used by (i.e., shared across)
-- multiple local processes.
--
-- Both abstractions can run asynchronous operations on remote nodes.
--
-- There is an implicit contract for async workers; Workers must exit
-- normally (i.e., should not call the 'exit', 'die' or 'terminate'
-- Cloud Haskell primitives), otherwise the 'AsyncResult' will end up being
-- @AsyncFailed DiedException@ instead of containing the result.
--
-- See "Control.Distributed.Process.Platform.Async.AsyncSTM",
--     "Control.Distributed.Process.Platform.Async.AsyncChan".
--
-- See "Control.Distributed.Platform.Task" for a high level layer built
-- on these capabilities.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Async
 ( -- * Exported Types
    Async(asyncWorker)
  , AsyncRef
  , AsyncTask(..)
  , AsyncResult(..)
  -- * Spawning asynchronous operations
  , async
  , asyncLinked
  , asyncSTM
  , asyncLinkedSTM
  , asyncChan
  , asyncLinkedChan
  , task
  , remoteTask
  -- * Cancelling asynchronous operations
  , cancel
  , cancelWait
  , cancelWith
  , cancelKill
    -- * Querying for results
  , poll
  , check
  , wait
-- , waitAny
-- , waitAnyTimeout
    -- * Waiting with timeouts
  , waitTimeout
  , waitCancelTimeout
  , waitCheckTimeout
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
  ( Serializable
  , SerializableDict
  )
import Control.Distributed.Process.Platform.Async.Types
  ( Async(..)
  , AsyncRef
  , AsyncTask(..)
  , AsyncResult(..)
  )
import qualified Control.Distributed.Process.Platform.Async.AsyncSTM as AsyncSTM
import qualified Control.Distributed.Process.Platform.Async.AsyncChan as AsyncChan
import Control.Distributed.Process.Platform.Time
import Data.Maybe
  ( fromMaybe
  )

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Spawn an 'AsyncTask' and return the 'Async' handle to it.
-- See 'asyncSTM'.
async :: (Serializable a) => Process a -> Process (Async a)
async t = asyncSTM (AsyncTask t)

-- | Spawn an 'AsyncTask' (linked to the calling process) and
-- return the 'Async' handle to it.
-- See 'asyncSTM'.
asyncLinked :: (Serializable a) => Process a -> Process (Async a)
asyncLinked p = AsyncSTM.newAsync AsyncSTM.asyncLinked (AsyncTask p)

-- | Spawn an 'AsyncTask' and return the 'Async' handle to it.
-- Uses the STM implementation, whose handles can be read by other
-- processes, though they're not @Serializable@.
--
-- See 'Control.Distributed.Process.Platform.Async.AsyncSTM'.
asyncSTM :: (Serializable a) => AsyncTask a -> Process (Async a)
asyncSTM = AsyncSTM.newAsync AsyncSTM.async

-- | Spawn an 'AsyncTask' (linked to the calling process) and return the
-- 'Async' handle to it. Uses the STM based implementation, whose handles
-- can be read by other processes, though they're not @Serializable@.
--
-- See 'Control.Distributed.Process.Platform.Async.AsyncSTM'.
asyncLinkedSTM :: (Serializable a) => AsyncTask a -> Process (Async a)
asyncLinkedSTM = AsyncSTM.newAsync AsyncSTM.asyncLinked

-- | Spawn an 'AsyncTask' and return the 'Async' handle to it.
-- Uses the channel based implementation, whose handles can be read by other
-- processes, though they're not @Serializable@.
--
-- See 'Control.Distributed.Process.Platform.Async.AsyncSTM'.
asyncChan :: (Serializable a) => AsyncTask a -> Process (Async a)
asyncChan = AsyncChan.newAsync AsyncChan.async

-- | Spawn an 'AsyncTask' (linked to the calling process) and return the
-- 'Async' handle to it. Uses the channel based implementation, whose handles
-- can be read by other processes, though they're not @Serializable@.
--
-- See 'Control.Distributed.Process.Platform.Async.AsyncChan'.
asyncLinkedChan :: (Serializable a) => AsyncTask a -> Process (Async a)
asyncLinkedChan = AsyncChan.newAsync AsyncChan.asyncLinked

-- | Wraps a regular @Process a@ as an 'AsyncTask'.
task :: Process a -> AsyncTask a
task = AsyncTask

-- | Wraps the components required and builds a remote 'AsyncTask'.
remoteTask :: Static (SerializableDict a)
              -> NodeId
              -> Closure (Process a)
              -> AsyncTask a
remoteTask = AsyncRemoteTask

-- | Check whether an 'Async' handle has completed yet. The status of the
-- action is encoded in the returned 'AsyncResult'. If the action has not
-- completed, the result will be 'AsyncPending', or one of the other
-- constructors otherwise. This function does not block waiting for the result.
-- Use 'wait' or 'waitTimeout' if you need blocking/waiting semantics.
{-# INLINE poll #-}
poll :: (Serializable a) => Async a -> Process (AsyncResult a)
poll = hPoll

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
-- See 'poll'.
check :: (Serializable a) => Async a -> Process (Maybe (AsyncResult a))
check hAsync = poll hAsync >>= \r -> case r of
  AsyncPending -> return Nothing
  ar           -> return (Just ar)

-- | Wait for an asynchronous operation to complete or timeout. This variant
-- returns the 'AsyncResult' itself, which will be 'AsyncPending' if the
-- result has not been made available, otherwise one of the other constructors.
{-# INLINE waitCheckTimeout #-}
waitCheckTimeout :: (Serializable a) =>
                    TimeInterval -> Async a -> Process (AsyncResult a)
waitCheckTimeout t hAsync =
  waitTimeout t hAsync >>= return . fromMaybe (AsyncPending)

-- | Wait for an asynchronous action to complete, and return its
-- value. The result (which can include failure and/or cancellation) is
-- encoded by the 'AsyncResult' type.
{-# INLINE wait #-}
wait :: Async a -> Process (AsyncResult a)
wait = hWait

-- | Wait for an asynchronous operation to complete or timeout. Returns
-- @Nothing@ if the 'AsyncResult' does not change from @AsyncPending@ within
-- the specified delay, otherwise @Just asyncResult@ is returned. If you want
-- to wait/block on the 'AsyncResult' without the indirection of @Maybe@ then
-- consider using 'wait' or 'waitCheckTimeout' instead.
{-# INLINE waitTimeout #-}
waitTimeout :: (Serializable a) =>
               TimeInterval -> Async a -> Process (Maybe (AsyncResult a))
waitTimeout = flip hWaitTimeout

-- | Wait for an asynchronous operation to complete or timeout. If it times out,
-- then 'cancelWait' the async handle instead.
--
waitCancelTimeout :: (Serializable a)
                  => TimeInterval
                  -> Async a
                  -> Process (AsyncResult a)
waitCancelTimeout t hAsync = do
  r <- waitTimeout t hAsync
  case r of
    Nothing -> cancelWait hAsync
    Just ar -> return ar

-- | Cancel an asynchronous operation. Cancellation is asynchronous in nature.
-- To wait for cancellation to complete, use 'cancelWait' instead. The notes
-- about the asynchronous nature of 'cancelWait' apply here also.
--
-- See 'Control.Distributed.Process'
{-# INLINE cancel #-}
cancel :: Async a -> Process ()
cancel = hCancel

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
cancelWait hAsync = cancel hAsync >> wait hAsync

-- | Cancel an asynchronous operation immediately.
-- This operation is performed by sending an /exit signal/ to the asynchronous
-- worker, which leads to the following semantics:
--
--     1. If the worker already completed, this function has no effect.
--
--     2. The worker might complete after this call, but before the signal arrives.
--
--     3. The worker might ignore the exit signal using @catchExit@.
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
cancelWith reason = (flip exit) reason . asyncWorker

-- | Like 'cancelWith' but sends a @kill@ instruction instead of an exit signal.
--
-- See 'Control.Distributed.Process.kill'
{-# INLINE cancelKill #-}
cancelKill :: String -> Async a -> Process ()
cancelKill reason = (flip kill) reason . asyncWorker

