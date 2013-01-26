-- | [Cloud Haskell Platform]
--
module Control.Distributed.Process.Platform
  (
    -- * Exported Types
    Addressable(..)
  , Recipient(..)
  , TerminateReason(..)
  , Tag
  , TagPool

    -- * Utilities and Extended Primitives
  , spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure
  , times
  , matchCond

    -- * Call/Tagging support
  , newTagPool
  , getTag

    -- * Registration and Process Lookup
  , whereisOrStart
  , whereisOrStartRemote

    -- remote call table
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.Internal.Types
  ( Recipient(..)
  , TerminateReason(..)
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
