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
-- The modules herein provides a set of operations for spawning Processes
-- and waiting for theie results.  It is a thin layer over the basic
-- concurrency operations provided by "Control.Distributed.Process".
-- The main feature it provides is a pre-canned set of APIs for waiting on the
-- result of one or more asynchronously running (and potentially distributed)
-- processes.
--
-----------------------------------------------------------------------------

module Control.Distributed.Platform.Async 
 ( -- types/data
    AsyncRef
  , AsyncWorkerId
  , AsyncGathererId
  , AsyncTask
  , AsyncCancel
  , AsyncResult(..)
  ) where

import Control.Distributed.Process

import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)

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
