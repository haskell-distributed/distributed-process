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

module Control.Distributed.Platform.Async
 ( -- types/data
    AsyncRef
  , AsyncTask
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
