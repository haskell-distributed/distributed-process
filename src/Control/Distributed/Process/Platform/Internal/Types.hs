-- | Types used throughout the Cloud Haskell framework
--
module Control.Distributed.Process.Platform.Internal.Types
  ( Tag
  , TagPool
  , newTagPool
  , getTag
  ) where

import Control.Distributed.Process
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)

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
