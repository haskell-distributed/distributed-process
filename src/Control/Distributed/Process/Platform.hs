-- | [Cloud Haskell Platform]
--
module Control.Distributed.Process.Platform
  (
    -- extra primitives
    spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure

  -- registration/start
  , whereisOrStart
  , whereisOrStartRemote

  -- matching
  , matchCond

    -- tags
  , Tag
  , TagPool
  , newTagPool
  , getTag

    -- common type
  , TerminateReason

  -- remote call table
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Internal.Types
  ( TerminateReason
  , Tag
  , TagPool
  , newTagPool
  , getTag
  )
import Control.Distributed.Process.Platform.Internal.Primitives hiding (__remoteTable)
import qualified Control.Distributed.Process.Platform.Internal.Primitives (__remoteTable)

-- remote table

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable =
   Control.Distributed.Process.Platform.Internal.Primitives.__remoteTable
