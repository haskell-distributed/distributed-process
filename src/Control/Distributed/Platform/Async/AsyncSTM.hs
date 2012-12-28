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
-- The main feature it provides is a pre-canned set of APIs for waiting on the
-- result of one or more asynchronously running (and potentially distributed)
-- processes.
--
-----------------------------------------------------------------------------

module Control.Distributed.Platform.Async.AsyncSTM where

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
import Control.Concurrent.STM
import GHC.Conc

--------------------------------------------------------------------------------
-- Cloud Haskell Async Process API                                            --
--------------------------------------------------------------------------------

-- | An handle for an asynchronous action spawned by 'async'.
-- Asynchronous operations are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- Handles of this type cannot cross remote boundaries.
data AsyncSTM a = AsyncSTM {
    worker    :: AsyncWorkerId
  , insulator :: AsyncGathererId
  , hWait     :: STM a
  }

-- | Spawns an asynchronous action in a new process.
--
-- There is currently a contract for async workers which is that they should
-- exit normally (i.e., they should not call the @exit selfPid reason@ nor
-- @terminate@ primitives), otherwise the 'AsyncResult' will end up being
-- @AsyncFailed DiedException@ instead of containing the result.
--
async :: (Serializable a) => AsyncTask a -> Process (AsyncSTM a)
async = asyncDo True

-- | This is a useful variant of 'async' that ensures an @AsyncChan@ is
-- never left running unintentionally. We ensure that if the caller's process
-- exits, that the worker is killed. Because an @AsyncChan@ can only be used
-- by the initial caller's process, if that process dies then the result
-- (if any) is discarded.
--
asyncLinked :: (Serializable a) => AsyncTask a -> Process (AsyncSTM a)
asyncLinked = asyncDo False

asyncDo :: (Serializable a) => Bool -> AsyncTask a -> Process (AsyncSTM a) 
asyncDo shouldLink task = do
    (wpid, gpid, hRes) <- spawnWorkers task shouldLink
    return AsyncSTM {
        worker    = wpid
      , insulator = gpid
      , hWait     = hRes
      }

spawnWorkers :: (Serializable a)
             => AsyncTask a
             -> Bool
             -> Process (AsyncRef, AsyncRef, STM a)
spawnWorkers task shouldLink = undefined
