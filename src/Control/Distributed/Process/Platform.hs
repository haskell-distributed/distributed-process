{- | [Cloud Haskell Platform]

It is /important/ not to be too general when catching exceptions in
handler code, because asynchonous exceptions provide cloud haskell with
its process termination mechanism. Two exceptions in particular, signal
the instigators intention to stop a process immediately, these are raised
in response to the @kill@ and @exit@ primitives provided by
the base distributed-process package.

-}
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
import qualified Control.Distributed.Process.Platform.Internal.Types      (__remoteTable)

-- remote table

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable =
   Control.Distributed.Process.Platform.Internal.Primitives.__remoteTable .
   Control.Distributed.Process.Platform.Internal.Types.__remoteTable
