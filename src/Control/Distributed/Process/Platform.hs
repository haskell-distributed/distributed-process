-- | [Cloud Haskell Platform]
--
module Control.Distributed.Process.Platform
  (
    -- extra primitives
    spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure

    -- tags
  , Tag
  , TagPool
  , newTagPool
  , getTag

  ) where

import Control.Distributed.Process.Platform.Internal.Types
import Control.Distributed.Process.Platform.Internal.Primitives
