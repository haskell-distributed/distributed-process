{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE DeriveFunctor             #-}

-- | shared, internal types for the Async package
module Control.Distributed.Process.Async.Internal.Types
 ( -- * Exported types
    Async(..)
  , AsyncRef
  , AsyncTask(..)
  , AsyncResult(..)
  , CancelWait(..)
  ) where

import Control.Concurrent.STM
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
  ( Serializable
  , SerializableDict
  )
import Data.Binary
import Data.Typeable (Typeable)
import Data.Monoid

import GHC.Generics

-- | A reference to an asynchronous action
type AsyncRef = ProcessId

-- | An handle for an asynchronous action spawned by 'async'.
-- Asynchronous operations are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- Handles of this type cannot cross remote boundaries, nor are they
-- @Serializable@.
data Async a = Async {
    _asyncWorker  :: AsyncRef
  , _asyncMonitor :: AsyncRef
  , _asyncWait    :: STM (AsyncResult a)
  } deriving (Functor)

instance Eq (Async a) where
  Async a b _ == Async c d _  =  a == c && b == d

instance Ord (Async a) where
  compare (Async a b _) (Async c d _) = a `compare` c <> b `compare` d

-- | A task to be performed asynchronously.
data AsyncTask a =
    AsyncTask {
        asyncTask :: Process a -- ^ the task to be performed
      }
  | AsyncRemoteTask {
        asyncTaskDict :: Static (SerializableDict a)
          -- ^ the serializable dict required to spawn a remote process
      , asyncTaskNode :: NodeId
          -- ^ the node on which to spawn the asynchronous task
      , asyncTaskProc :: Closure (Process a)
          -- ^ the task to be performed, wrapped in a closure environment
      }

-- | Represents the result of an asynchronous action, which can be in one of
-- several states at any given time.
data AsyncResult a =
    AsyncDone a                 -- ^ a completed action and its result
  | AsyncFailed DiedReason      -- ^ a failed action and the failure reason
  | AsyncLinkFailed DiedReason  -- ^ a link failure and the reason
  | AsyncCancelled              -- ^ a cancelled action
  | AsyncPending                -- ^ a pending action (that is still running)
    deriving (Typeable, Generic, Functor)


instance Serializable a => Binary (AsyncResult a) where

deriving instance Eq a => Eq (AsyncResult a)
deriving instance Show a => Show (AsyncResult a)

-- | A message to cancel Async operations
data CancelWait = CancelWait
    deriving (Typeable, Generic)
instance Binary CancelWait
