{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE StandaloneDeriving        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Platform.Async
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
-- The basic type is @'Async' a@, which represents an asynchronous
-- @Process@ that will return a value of type @a@, or exit with a failure
-- reason. An @Async@ corresponds logically to a worker @Process@, and its
-- 'ProcessId' can be obtained with 'worker', although that should rarely
-- be necessary.
--
-----------------------------------------------------------------------------

module Control.Distributed.Platform.Async.AsyncChan
  ( -- types/data
    AsyncRef
  , AsyncWorkerId
  , AsyncGathererId
  , AsyncTask
  , AsyncCancel
  , AsyncChan(worker)
  , AsyncResult(..)
  -- functions for starting/spawning
  , async
  , asyncLinked
  -- and stopping/killing
  , cancel
  , cancelWait
  -- functions to query an async-result
  , poll
  , check
  , wait
  , waitAny
  , waitTimeout
  , waitCheckTimeout
  ) where

import Control.Distributed.Platform.Async
import Control.Distributed.Platform.Timer
  ( intervalToMs
  )
import Control.Distributed.Platform.Internal.Types
  ( CancelWait(..)
  , TimeInterval()
  )
import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import Data.Maybe
  ( fromMaybe
  )

--------------------------------------------------------------------------------
-- Cloud Haskell Async Process API                                            --
--------------------------------------------------------------------------------

-- | Private channel used to synchronise task results
type InternalChannel a = (SendPort (AsyncResult a), ReceivePort (AsyncResult a))

-- | An handle for an asynchronous action spawned by 'async'.
-- Asynchronous operations are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- Handles of this type cannot cross remote boundaries.
data AsyncChan a = AsyncChan {
    worker    :: AsyncWorkerId
  , insulator :: AsyncGathererId
  , channel   :: (InternalChannel a)
  }

-- | Spawns an asynchronous action in a new process.
--
-- There is currently a contract for async workers which is that they should
-- exit normally (i.e., they should not call the @exit selfPid reason@ nor
-- @terminate@ primitives), otherwise the 'AsyncResult' will end up being
-- @AsyncFailed DiedException@ instead of containing the result.
--
async :: (Serializable a) => AsyncTask a -> Process (AsyncChan a)
async = asyncDo True

-- | This is a useful variant of 'async' that ensures an @AsyncChan@ is
-- never left running unintentionally. We ensure that if the caller's process
-- exits, that the worker is killed. Because an @AsyncChan@ can only be used
-- by the initial caller's process, if that process dies then the result
-- (if any) is discarded.
--
asyncLinked :: (Serializable a) => AsyncTask a -> Process (AsyncChan a)
asyncLinked = async

asyncDo :: (Serializable a) => Bool -> AsyncTask a -> Process (AsyncChan a) 
asyncDo shouldLink task = do
    (wpid, gpid, chan) <- spawnWorkers task shouldLink
    return AsyncChan {
        worker    = wpid
      , insulator = gpid
      , channel   = chan
      }

spawnWorkers :: (Serializable a)
             => AsyncTask a
             -> Bool
             -> Process (AsyncRef, AsyncRef,
                        (SendPort (AsyncResult a), ReceivePort (AsyncResult a)))
spawnWorkers task shouldLink = do
    root <- getSelfPid
    chan <- newChan
  
    -- listener/response proxy
    insulatorPid <- spawnLocal $ do
        workerPid <- spawnLocal $ do
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

-- | Check whether an 'AsyncChan' has completed yet. The status of the
-- action is encoded in the returned 'AsyncResult'. If the action has not
-- completed, the result will be 'AsyncPending', or one of the other
-- constructors otherwise. This function does not block waiting for the result.
-- Use 'wait' or 'waitTimeout' if you need blocking/waiting semantics.
-- See 'Async'.
poll :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
poll hAsync = do
  r <- receiveChanTimeout 0 $ snd (channel hAsync)
  return $ fromMaybe (AsyncPending) r

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
-- See 'poll'.
check :: (Serializable a) => AsyncChan a -> Process (Maybe (AsyncResult a))
check hAsync = poll hAsync >>= \r -> case r of
  AsyncPending -> return Nothing
  ar           -> return (Just ar)  

-- | Wait for an asynchronous operation to complete or timeout. This variant
-- returns the 'AsyncResult' itself, which will be 'AsyncPending' if the
-- result has not been made available, otherwise one of the other constructors.
waitCheckTimeout :: (Serializable a) =>
                    TimeInterval -> AsyncChan a -> Process (AsyncResult a)
waitCheckTimeout t hAsync =
  waitTimeout t hAsync >>= return . fromMaybe (AsyncPending)

-- | Wait for an asynchronous action to complete, and return its
-- value. The outcome of the action is encoded as an 'AsyncResult'.
--
wait :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
wait hAsync = receiveChan $ snd (channel hAsync)

-- | Wait for an asynchronous operation to complete or timeout. Returns
-- @Nothing@ if the 'AsyncResult' does not change from @AsyncPending@ within
-- the specified delay, otherwise @Just asyncResult@ is returned. If you want
-- to wait/block on the 'AsyncResult' without the indirection of @Maybe@ then
-- consider using 'wait' or 'waitCheckTimeout' instead. 
waitTimeout :: (Serializable a) =>
               TimeInterval -> AsyncChan a -> Process (Maybe (AsyncResult a))
waitTimeout t hAsync =
  receiveChanTimeout (intervalToMs t) $ snd (channel hAsync)

-- | Wait for any of the supplied @AsyncChans@s to complete. If multiple
-- 'Async's complete, then the value returned corresponds to the first
-- completed 'Async' in the list. Only /unread/ 'Async's are of value here,
-- because 'AsyncChan' does not hold on to its result after it has been read! 
--
-- This function is analagous to the @mergePortsBiased@ primitive.
-- See 'Control.Distibuted.Process.mergePortsBiased'
waitAny :: (Serializable a)
        => [AsyncChan a]
        -> Process (AsyncResult a)
waitAny asyncs =
  let ports = map (snd . channel) asyncs
  in mergePortsBiased ports >>= receiveChan  

-- | Cancel an asynchronous operation. To wait for cancellation to complete, use
-- 'cancelWait' instead.
cancel :: AsyncChan a -> Process ()
cancel (AsyncChan _ g _) = send g CancelWait

-- | Cancel an asynchronous operation and wait for the cancellation to complete.
-- Because of the asynchronous nature of message passing, the instruction to
-- cancel will race with the asynchronous worker, so it is /entirely possible/
-- that the 'AsyncResult' returned will not necessarily be 'AsyncCancelled'.
--
cancelWait :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
cancelWait hAsync = cancel hAsync >> wait hAsync 
