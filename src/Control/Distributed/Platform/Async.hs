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

module Control.Distributed.Platform.Async
  ( -- types/data
    AsyncRef
  , AsyncWorkerId
  , AsyncGathererId
  , AsyncTask
  , AsyncCancel
  , AsyncChan(worker)
  , AsyncResult(..)
  -- functions for starting/spawning
  , asyncChan
  , asyncChanLinked
  -- and stopping/killing
  , cancelChan
  , cancelChanWait
  -- functions to query an async-result
  , pollChan
  , checkChan
  , waitChan
  , waitChanTimeout
  , waitChanCheckTimeout
  ) where

import Control.Distributed.Platform.Timer
  ( intervalToMs
  )
import Control.Distributed.Platform.Internal.Types
  ( CancelWait(..)
  , TimeInterval()
  )
import Control.Distributed.Process
import Control.Distributed.Process.Serializable

import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)
import Data.Maybe
  ( fromMaybe
  )

--------------------------------------------------------------------------------
-- Cloud Haskell Async Process API                                            --
--------------------------------------------------------------------------------

-- | A reference to an asynchronous action
type AsyncRef = ProcessId

-- | A reference to an asynchronous worker
type AsyncWorkerId   = AsyncRef

-- | A reference to an asynchronous "gatherer"
type AsyncGathererId = AsyncRef

-- | A task to be performed asynchronously. This can either take the
-- form of an action that runs over some type @a@ in the @Process@ monad,
-- or a tuple that adds the node on which the asynchronous task should be
-- spawned - in the @Process a@ case the task is spawned on the local node
type AsyncTask a = Process a

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

-- | Represents the result of an asynchronous action, which can be in one of 
-- several states at any given time.
data AsyncResult a =
    AsyncDone a                 -- ^ a completed action and its result
  | AsyncFailed DiedReason      -- ^ a failed action and the failure reason
  | AsyncLinkFailed DiedReason  -- ^ a link failure and the reason
  | AsyncCancelled              -- ^ a cancelled action
  | AsyncPending                -- ^ a pending action (that is still running)
    deriving (Typeable)
$(derive makeBinary ''AsyncResult)

deriving instance Eq a => Eq (AsyncResult a)
deriving instance Show a => Show (AsyncResult a)

-- | An async cancellation takes an 'AsyncRef' and does some cancellation
-- operation in the @Process@ monad.
type AsyncCancel = AsyncRef -> Process () -- note [local cancel only]

-- note [local cancel only]
-- The cancellation is only ever sent to the insulator process, which is always
-- run on the local node. That could be a limitation, as there's nothing in
-- 'Async' data profile to stop it being sent remotely. At *that* point, we'd
-- need to make the cancellation remote-able too however.   

-- | Spawns an asynchronous action in a new process.
--
-- There is currently a contract for async workers which is that they should
-- exit normally (i.e., they should not call the @exit selfPid reason@ nor
-- @terminate@ primitives), otherwise the 'AsyncResult' will end up being
-- @AsyncFailed DiedException@ instead of containing the result.
--
asyncChan :: (Serializable a) => AsyncTask a -> Process (AsyncChan a)
asyncChan = asyncChanDo False

-- | This is a useful variant of 'asyncChan' that ensures an @AsyncChan@ is
-- never left running unintentionally. We ensure that if the caller's process
-- exits, that the worker is killed. Because an @AsyncChan@ can only be used
-- by the initial caller's process, if that process dies then the result
-- (if any) is discarded.
--
asyncChanLinked :: (Serializable a) => AsyncTask a -> Process (AsyncChan a)
asyncChanLinked = asyncChanDo True

asyncChanDo :: (Serializable a) => Bool -> AsyncTask a -> Process (AsyncChan a) 
asyncChanDo shouldLink task = do
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
pollChan :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
pollChan hAsync = do
  r <- receiveChanTimeout 0 $ snd (channel hAsync)
  return $ fromMaybe (AsyncPending) r

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
-- See 'poll'.
checkChan :: (Serializable a) => AsyncChan a -> Process (Maybe (AsyncResult a))
checkChan hAsync = pollChan hAsync >>= \r -> case r of
  AsyncPending -> return Nothing
  ar           -> return (Just ar)  

-- | Wait for an asynchronous operation to complete or timeout. This variant
-- returns the 'AsyncResult' itself, which will be 'AsyncPending' if the
-- result has not been made available, otherwise one of the other constructors.
waitChanCheckTimeout :: (Serializable a) =>
                    TimeInterval -> AsyncChan a -> Process (AsyncResult a)
waitChanCheckTimeout t hAsync =
  waitChanTimeout t hAsync >>= return . fromMaybe (AsyncPending)

-- | Wait for an asynchronous action to complete, and return its
-- value. The outcome of the action is encoded as an 'AsyncResult'.
--
waitChan :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
waitChan hAsync = receiveChan $ snd (channel hAsync)

-- | Wait for an asynchronous operation to complete or timeout. Returns
-- @Nothing@ if the 'AsyncResult' does not change from @AsyncPending@ within
-- the specified delay, otherwise @Just asyncResult@ is returned. If you want
-- to wait/block on the 'AsyncResult' without the indirection of @Maybe@ then
-- consider using 'wait' or 'waitCheckTimeout' instead. 
waitChanTimeout :: (Serializable a) =>
               TimeInterval -> AsyncChan a -> Process (Maybe (AsyncResult a))
waitChanTimeout t hAsync =
  receiveChanTimeout (intervalToMs t) $ snd (channel hAsync)

-- | Cancel an asynchronous operation. To wait for cancellation to complete, use
-- 'cancelWait' instead.
cancelChan :: AsyncChan a -> Process ()
cancelChan (AsyncChan _ g _) = send g CancelWait

-- | Cancel an asynchronous operation and wait for the cancellation to complete.
-- Because of the asynchronous nature of message passing, the instruction to
-- cancel will race with the asynchronous worker, so it is /entirely possible/
-- that the 'AsyncResult' returned will not necessarily be 'AsyncCancelled'.
--
cancelChanWait :: (Serializable a) => AsyncChan a -> Process (AsyncResult a)
cancelChanWait hAsync = cancelChan hAsync >> waitChan hAsync 
