{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE StandaloneDeriving        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Async.AsyncChan
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a set of operations for spawning Process operations
-- and waiting for their results.  It is a thin layer over the basic
-- concurrency operations provided by "Control.Distributed.Process".
-- The main feature it provides is a pre-canned set of APIs for waiting on the
-- result of one or more asynchronously running (and potentially distributed)
-- processes.
--
-- The async handles returned by this module cannot be used by processes other
-- than the caller of 'async', and are not 'Serializable'. Specifically, calls
-- that block until an async worker completes (i.e., all variants of 'wait')
-- will /never return/ if called from a different process.
--
-- > h <- newEmptyMVar
-- > outer <- spawnLocal $ async runMyAsyncTask >>= liftIO $ putMVar h
-- > hAsync <- liftIO $ takeMVar h
-- > say "this expression will never return, because hAsync belongs to 'outer'"
-- > wait hAsync
--
-- As with 'Control.Distributed.Platform.Async.Async', workers can be
-- started on a local or remote node.
--
-- See "Control.Distributed.Platform.Async".
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Async.AsyncChan
  ( -- * Exported types
    AsyncRef
  , AsyncTask(..)
  , AsyncChan(worker)
  , AsyncResult(..)
  , Async(asyncWorker)
  -- functions for starting/spawning
  , async
  , asyncLinked
  -- and stopping/killing
  , cancel
  , cancelWait
  , cancelWith
  , cancelKill
    -- * Querying for results
  , poll
  , check
  , wait
  , waitAny
    -- * Waiting with timeouts
  , waitAnyTimeout
  , waitTimeout
  , waitCancelTimeout
  , waitCheckTimeout
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Async.Types
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Internal.Types
import Control.Distributed.Process.Serializable
import Data.Maybe
  ( fromMaybe
  )

-- | Private channel used to synchronise task results
type InternalChannel a = (SendPort (AsyncResult a), ReceivePort (AsyncResult a))

--------------------------------------------------------------------------------
-- Cloud Haskell Typed Channel Async API                                      --
--------------------------------------------------------------------------------

-- | A handle for an asynchronous action spawned by 'async'.
-- Asynchronous actions are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- Handles of this type cannot cross remote boundaries. Furthermore, handles
-- of this type /must not/ be passed to functions in this module by processes
-- other than the caller of 'async' - that is, this module provides asynchronous
-- actions whose results are accessible *only* by the initiating process. This
-- limitation is imposed becuase of the use of type channels, for which the
-- @ReceivePort@ component is effectively /thread local/.
--
-- See 'async'
data AsyncChan a = AsyncChan {
    worker    :: AsyncRef
  , insulator :: AsyncRef
  , channel   :: (InternalChannel a)
  }

-- | Spawns an asynchronous action in a new process.
-- We ensure that if the caller's process exits, that the worker is killed.
-- Because an @AsyncChan@ can only be used by the initial caller's process, if
-- that process dies then the result (if any) is discarded. If a process other
-- than the initial caller attempts to obtain the result of an asynchronous
-- action, the behaviour is undefined. It is /highly likely/ that such a
-- process will block indefinitely, quite possible that such behaviour could lead
-- to deadlock and almost certain that resource starvation will occur. /Do Not/
-- share the handles returned by this function across multiple processes.
--
-- If you need to spawn an asynchronous operation whose handle can be shared by
-- multiple processes then use the 'AsyncSTM' module instead.
--
-- There is currently a contract for async workers, that they should
-- exit normally (i.e., they should not call the @exit@ or @kill@ with their own
-- 'ProcessId' nor use the @terminate@ primitive to cease functining), otherwise
-- the 'AsyncResult' will end up being @AsyncFailed DiedException@ instead of
-- containing the desired result.
--
async :: (Serializable a) => AsyncTask a -> Process (AsyncChan a)
async = asyncDo True

-- | For *AsyncChan*, 'async' already ensures an @AsyncChan@ is
-- never left running unintentionally. This function is provided for compatibility
-- with other /async/ implementations that may offer different semantics for
-- @async@ with regards linking.
--
-- @asyncLinked = async@
--
asyncLinked :: (Serializable a) => AsyncTask a -> Process (AsyncChan a)
asyncLinked = async

asyncDo :: (Serializable a) => Bool -> AsyncTask a -> Process (AsyncChan a)
asyncDo shouldLink (AsyncRemoteTask d n c) =
  let proc = call d n c in asyncDo shouldLink AsyncTask { asyncTask = proc }
asyncDo shouldLink (AsyncTask proc) = do
    (wpid, gpid, chan) <- spawnWorkers proc shouldLink
    return AsyncChan {
        worker    = wpid
      , insulator = gpid
      , channel   = chan
      }

-- private API
spawnWorkers :: (Serializable a)
             => Process a
             -> Bool
             -> Process (AsyncRef, AsyncRef, InternalChannel a)
spawnWorkers task shouldLink = do
    root <- getSelfPid
    chan <- newChan

    -- listener/response proxy
    insulatorPid <- spawnLocal $ do
        workerPid <- spawnLocal $ do
            () <- expect
            r <- task
            sendChan (fst chan) (AsyncDone r)

        send root workerPid   -- let the parent process know the worker pid

        wref <- monitor workerPid
        rref <- case shouldLink of
                    True  -> monitor root >>= return . Just
                    False -> return Nothing
        finally (pollUntilExit workerPid chan)
                (unmonitor wref >>
                    return (maybe (return ()) unmonitor rref))

    workerPid <- expect
    send workerPid ()
    return (workerPid, insulatorPid, chan)
  where
    -- blocking receive until we see an input message
    pollUntilExit :: (Serializable a)
                  => ProcessId
                  -> (SendPort (AsyncResult a), ReceivePort (AsyncResult a))
                  -> Process ()
    pollUntilExit wpid (replyTo, _) = do
      r <- receiveWait [
          match (\(ProcessMonitorNotification _ pid' r) ->
                return (Right (pid', r)))
        , match (\c@(CancelWait) -> kill wpid "cancel" >> return (Left c))
        ]
      case r of
          Left  CancelWait -> sendChan replyTo AsyncCancelled
          Right (fpid, d)
            | fpid == wpid -> case d of
                                  DiedNormal -> return ()
                                  _          -> sendChan replyTo (AsyncFailed d)
            | otherwise    -> kill wpid "linkFailed"

-- | Check whether an 'AsyncChan' has completed yet.
--
-- See "Control.Distributed.Process.Platform.Async".
poll :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
poll hAsync = do
  r <- receiveChanTimeout 0 $ snd (channel hAsync)
  return $ fromMaybe (AsyncPending) r

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
--
-- See "Control.Distributed.Process.Platform.Async".
check :: (Serializable a) => AsyncChan a -> Process (Maybe (AsyncResult a))
check hAsync = poll hAsync >>= \r -> case r of
  AsyncPending -> return Nothing
  ar           -> return (Just ar)

-- | Wait for an asynchronous operation to complete or timeout.
--
-- See "Control.Distributed.Process.Platform.Async".
waitCheckTimeout :: (Serializable a) =>
                    TimeInterval -> AsyncChan a -> Process (AsyncResult a)
waitCheckTimeout t hAsync =
  waitTimeout t hAsync >>= return . fromMaybe (AsyncPending)

-- | Wait for an asynchronous action to complete, and return its
-- value. The outcome of the action is encoded as an 'AsyncResult'.
--
-- See "Control.Distributed.Process.Platform.Async".
wait :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
wait hAsync = receiveChan $ snd (channel hAsync)

-- | Wait for an asynchronous operation to complete or timeout.
--
-- See "Control.Distributed.Process.Platform.Async".
waitTimeout :: (Serializable a) =>
               TimeInterval -> AsyncChan a -> Process (Maybe (AsyncResult a))
waitTimeout t hAsync =
  receiveChanTimeout (asTimeout t) $ snd (channel hAsync)

-- | Wait for an asynchronous operation to complete or timeout. If it times out,
-- then 'cancelWait' the async handle instead.
--
waitCancelTimeout :: (Serializable a)
                  => TimeInterval
                  -> AsyncChan a
                  -> Process (AsyncResult a)
waitCancelTimeout t hAsync = do
  r <- waitTimeout t hAsync
  case r of
    Nothing -> cancelWait hAsync
    Just ar -> return ar

-- | Wait for any of the supplied @AsyncChans@s to complete. If multiple
-- 'Async's complete, then the value returned corresponds to the first
-- completed 'Async' in the list. Only /unread/ 'Async's are of value here,
-- because 'AsyncChan' does not hold on to its result after it has been read!
--
-- This function is analagous to the @mergePortsBiased@ primitive.
--
-- See "Control.Distibuted.Process.mergePortsBiased".
waitAny :: (Serializable a)
        => [AsyncChan a]
        -> Process (AsyncResult a)
waitAny asyncs =
  let ports = map (snd . channel) asyncs in recv ports
  where recv :: (Serializable a) => [ReceivePort a] -> Process a
        recv ps = mergePortsBiased ps >>= receiveChan

-- | Like 'waitAny' but times out after the specified delay.
waitAnyTimeout :: (Serializable a)
               => TimeInterval
               -> [AsyncChan a]
               -> Process (Maybe (AsyncResult a))
waitAnyTimeout delay asyncs =
  let ports = map (snd . channel) asyncs
  in mergePortsBiased ports >>= receiveChanTimeout (asTimeout delay)

-- | Cancel an asynchronous operation. Cancellation is asynchronous in nature.
--
-- See "Control.Distributed.Process.Platform.Async".
cancel :: AsyncChan a -> Process ()
cancel (AsyncChan _ g _) = send g CancelWait

-- | Cancel an asynchronous operation and wait for the cancellation to complete.
--
-- See "Control.Distributed.Process.Platform.Async".
cancelWait :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
cancelWait hAsync = cancel hAsync >> wait hAsync

-- | Cancel an asynchronous operation immediately.
--
-- See "Control.Distributed.Process.Platform.Async".
cancelWith :: (Serializable b) => b -> AsyncChan a -> Process ()
cancelWith reason = (flip exit) reason . worker

-- | Like 'cancelWith' but sends a @kill@ instruction instead of an exit.
--
-- See "Control.Distributed.Process.Platform.Async".
cancelKill :: String -> AsyncChan a -> Process ()
cancelKill reason = (flip kill) reason . worker
