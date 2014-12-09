{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveGeneric             #-}

-- | shared, internal types for the Async package
module Control.Distributed.Process.Platform.Async.Types
 ( -- * Exported types
    Async(..)
  , AsyncRef
  , AsyncTask(..)
  , AsyncResult(..)
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
  ( Serializable
  , SerializableDict
  )
import Data.Binary
import Data.Typeable (Typeable)

import GHC.Generics

-- | An opaque handle that refers to an asynchronous operation.
data Async a = Async {
    hPoll        :: Process (AsyncResult a)
  , hWait        :: Process (AsyncResult a)
  , hWaitTimeout :: TimeInterval -> Process (Maybe (AsyncResult a))
  , hCancel      :: Process ()
  , asyncWorker  :: ProcessId
  }

-- | A reference to an asynchronous action
type AsyncRef = ProcessId

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
    deriving (Typeable, Generic)

instance Serializable a => Binary (AsyncResult a) where

deriving instance Eq a => Eq (AsyncResult a)
deriving instance Show a => Show (AsyncResult a)

