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

  -- * Remote call table
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Internal.Types
import Control.Distributed.Process.Platform.Internal.Primitives hiding (__remoteTable)
import qualified Control.Distributed.Process.Platform.Internal.Primitives (__remoteTable) 

-- remote table

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable = 
   Control.Distributed.Process.Platform.Internal.Primitives.__remoteTable
