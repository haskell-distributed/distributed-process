{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE StandaloneDeriving        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Platform.Async.AsyncSTM
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
--
-- The difference between 'Control.Distributed.Platform.Async.Async' and
-- 'Control.Distributed.Platform.Async.AsyncChan' is that handles of the
-- former (i.e., returned by /this/ module) can be sent across a remote
-- boundary, where the receiver can use the API calls to wait on the
-- results of the computation at their end.
--
-- Like 'Control.Distributed.Platform.Async.AsyncChan', workers can be
-- started on a local or remote node.
-----------------------------------------------------------------------------

module Control.Distributed.Platform.Async.AsyncSTM
  ( -- types/data
    AsyncRef
  , AsyncTask
  , AsyncSTM(_asyncWorker)
  -- functions for starting/spawning
  , async
  , asyncLinked
  -- and stopping/killing
--  , cancel
--  , cancelWait
--  , cancelWith
--  , cancelKill
  -- functions to query an async-result
  , poll
  -- , check
  , wait
  -- , waitAny
  -- , waitAnyTimeout
  -- , waitTimeout
  -- , waitCheckTimeout
  -- STM versions
  , pollSTM
  ) where


import Control.Applicative
import Control.Concurrent.STM
import Control.Distributed.Platform.Async
import Control.Distributed.Platform.Internal.Types
  ( CancelWait(..)
  )
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Monad
import Data.Maybe
  ( fromMaybe
  )
import Prelude hiding (catch)

--------------------------------------------------------------------------------
-- Cloud Haskell STM Async Process API                                        --
--------------------------------------------------------------------------------

-- | An handle for an asynchronous action spawned by 'async'.
-- Asynchronous operations are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- Handles of this type cannot cross remote boundaries, nor are they
-- @Serializable@.
data AsyncSTM a = AsyncSTM {
    _asyncWorker  :: AsyncRef
  , _asyncMonitor :: AsyncRef
  , _asyncWait    :: STM (AsyncResult a)
  }

instance Eq (AsyncSTM a) where
  AsyncSTM a b _ == AsyncSTM c d _  =  a == c && b == d

-- instance Functor AsyncSTM where
--  fmap f (AsyncSTM a b w) = AsyncSTM a b (fmap (fmap f) w)

-- | Spawns an asynchronous action in a new process.
--
-- There is currently a contract for async workers which is that they should
-- exit normally (i.e., they should not call the @exit selfPid reason@ nor
-- @terminate@ primitives), otherwise the 'AsyncResult' will end up being
-- @AsyncFailed DiedException@ instead of containing the result.
--
async :: (Serializable a) => AsyncTask a -> Process (AsyncSTM a)
async = asyncDo False

-- | This is a useful variant of 'async' that ensures an @AsyncChan@ is
-- never left running unintentionally. We ensure that if the caller's process
-- exits, that the worker is killed. Because an @AsyncChan@ can only be used
-- by the initial caller's process, if that process dies then the result
-- (if any) is discarded.
--
asyncLinked :: (Serializable a) => AsyncTask a -> Process (AsyncSTM a)
asyncLinked = asyncDo True

asyncDo :: (Serializable a) => Bool -> AsyncTask a -> Process (AsyncSTM a)
asyncDo shouldLink task = do
    root <- getSelfPid
    result <- liftIO $ newEmptyTMVarIO
    
    -- listener/response proxy
    mPid <- spawnLocal $ do
        wPid <- spawnLocal $ do
            () <- expect
            r <- task
            void $ liftIO $ atomically $ putTMVar result (AsyncDone r)

        send root wPid   -- let the parent process know the worker pid

        wref <- monitor wPid
        rref <- case shouldLink of
                    True  -> monitor root >>= return . Just
                    False -> return Nothing
        finally (pollUntilExit wPid result)
                (unmonitor wref >>
                    return (maybe (return ()) unmonitor rref))

    workerPid <- expect
    send workerPid ()

    return AsyncSTM {
          _asyncWorker  = workerPid
        , _asyncMonitor = mPid
        , _asyncWait    = (readTMVar result)
        }

  where
    pollUntilExit :: (Serializable a)
                  => ProcessId
                  -> TMVar (AsyncResult a)
                  -> Process ()
    pollUntilExit wpid result' = do
      r <- receiveWait [
          match (\c@(CancelWait) -> kill wpid "cancel" >> return (Left c))
        , match (\(ProcessMonitorNotification _ pid' r) ->
                  return (Right (pid', r)))
        ]
      case r of
          Left CancelWait
            -> liftIO $ atomically $ putTMVar result' AsyncCancelled
          Right (fpid, d)
            | fpid == wpid
              -> case d of
                     DiedNormal -> return ()
                     _          -> liftIO $ atomically $ putTMVar result' (AsyncFailed d)
            | otherwise -> kill wpid "linkFailed"

-- | Check whether an 'AsyncSTM' has completed yet. The status of the
-- action is encoded in the returned 'AsyncResult'. If the action has not
-- completed, the result will be 'AsyncPending', or one of the other
-- constructors otherwise. This function does not block waiting for the result.
-- Use 'wait' or 'waitTimeout' if you need blocking/waiting semantics.
-- See 'Async'.
poll :: (Serializable a) => AsyncSTM a -> Process (AsyncResult a)
poll hAsync = do
  r <- liftIO $ atomically $ pollSTM hAsync
  return $ fromMaybe (AsyncPending) r

-- | Wait for an asynchronous action to complete, and return its
-- value. The result (which can include failure and/or cancellation) is
-- encoded by the 'AsyncResult' type.
--
-- > wait = liftIO . atomically . waitSTM
--
{-# INLINE wait #-}
wait :: AsyncSTM a -> Process (AsyncResult a)
wait = liftIO . atomically . waitSTM

-- | A version of 'wait' that can be used inside an STM transaction.
--
waitSTM :: AsyncSTM a -> STM (AsyncResult a)
waitSTM (AsyncSTM _ _ w) = w

-- | A version of 'poll' that can be used inside an STM transaction.
--
{-# INLINE pollSTM #-}
pollSTM :: AsyncSTM a -> STM (Maybe (AsyncResult a))
pollSTM (AsyncSTM _ _ w) = (Just <$> w) `orElse` return Nothing

