{-# LANGUAGE DeriveDataTypeable        #-}

-- | Types used throughout the Cloud Haskell framework
--
module Control.Distributed.Process.Platform.Internal.Types
  ( Tag
  , TagPool
  , newTagPool
  , getTag
  , RegisterSelf(..)
  , CancelWait(..)
  , Channel
  , TerminateReason(..)
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Control.Distributed.Process
import Control.Distributed.Process.Serializable ()
import Data.Binary
  ( Binary(put, get)
  , putWord8
  , getWord8)
import Data.Typeable (Typeable)

-- | Simple representation of a channel.
type Channel a = (SendPort a, ReceivePort a)

-- | Used internally in whereisOrStart. Send as (RegisterSelf,ProcessId).
data RegisterSelf = RegisterSelf deriving Typeable
instance Binary RegisterSelf where
  put _ = return ()
  get = return RegisterSelf

-- | Tags provide uniqueness for messages, so that they can be
-- matched with their response.
type Tag = Int

-- | Generates unique 'Tag' for messages and response pairs.
-- Each process that depends, directly or indirectly, on
-- the call mechanisms in "Control.Distributed.Process.Global.Call"
-- should have at most one TagPool on which to draw unique message
-- tags.
type TagPool = MVar Tag

-- | Create a new per-process source of unique
-- message identifiers.
newTagPool :: Process TagPool
newTagPool = liftIO $ newMVar 0

-- | Extract a new identifier from a 'TagPool'.
getTag :: TagPool -> Process Tag
getTag tp = liftIO $ modifyMVar tp (\tag -> return (tag+1,tag))

-- | Wait cancellation message.
data CancelWait = CancelWait
    deriving (Eq, Show, Typeable)

instance Binary CancelWait where
  put CancelWait = return ()
  get = return CancelWait

-- | A ubiquitous /shutdown signal/ that can be used
-- to maintain a consistent shutdown/stop protocol for
-- any process that wishes to handle it.
data Shutdown = Shutdown
  deriving (Typeable, Show, Eq)

instance Binary Shutdown where
  get   = return Shutdown
  put _ = return ()

-- | Provides a /reason/ for process termination.
data TerminateReason =
    TerminateNormal       -- ^ indicates normal exit
  | TerminateShutdown     -- ^ normal response to a 'Shutdown'
  | TerminateOther String -- ^ abnormal (error) shutdown
  deriving (Typeable, Eq, Show)

instance Binary TerminateReason where
  put TerminateNormal    = putWord8 1
  put TerminateShutdown  = putWord8 2
  put (TerminateOther s) = putWord8 3 >> put s

  get = do
    header <- getWord8
    case header of
      1 -> return TerminateNormal
      2 -> return TerminateShutdown
      3 -> TerminateOther <$> get
      _ -> fail "TerminateReason.get: invalid"
