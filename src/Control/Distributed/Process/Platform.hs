{- | [Cloud Haskell Platform]

[Evaluation Strategies and Support for NFData]

When sending messages to a local process (i.e., intra-node), the default
approach is to encode (i.e., serialise) the message /anyway/, just to
ensure that no unevaluated thunks are passed to the receiver.
In distributed-process, you must explicitly choose to use /unsafe/ primitives
that do nothing to ensure evaluation, since this might cause an error in the
receiver which would be difficult to debug. Using @NFData@, it is possible
to force evaluation, but there is no way to ensure that both the @NFData@
and @Binary@ instances do so in the same way (i.e., to the same depth, etc)
therefore automatic use of @NFData@ is not possible in distributed-process.

By contrast, distributed-process-platform makes extensive use of @NFData@
to force evaluation (and avoid serialisation overheads during intra-node
communication), via the @NFSerializable@ type class. This does nothing to
fix the potential disparity between @NFData@ and @Binary@ instances, so you
should verify that your data is being handled as expected (e.g., by sticking
to strict fields, or some such) and bear in mind that things could go wrong.

The @UnsafePrimitives@ module in /this/ library will force evaluation before
calling the @UnsafePrimitives@ in distributed-process, which - if you've
vetted everything correctly - should provide a bit more safety, whilst still
keeping performance at an acceptable level.

Users of the various service and utility models (such as @ManagedProcess@ and
the @Service@ and @Task@ APIs) should consult the sub-system specific
documentation for instructions on how to utilise these features.

IMPORTANT NOTICE: Despite the apparent safety of forcing evaluation before
sending, we /still/ cannot make any actual guarantees about the evaluation
semantics of these operations, and therefore the /unsafe/ moniker will remain
in place, in one form or another, for all functions and modules that use them.

[Error/Exception Handling]

It is /important/ not to be too general when catching exceptions in
cloud haskell application, because asynchonous exceptions provide cloud haskell
with its process termination mechanism. Two exception types in particular,
signal the instigator's intention to stop a process immediately, which are
raised (i.e., thrown) in response to the @kill@ and @exit@ primitives provided
by the base distributed-process package.

You should generally try to keep exception handling code to the lowest (i.e.,
most specific) scope possible. If you wish to trap @exit@ signals, use the
various flavours of @catchExit@ primitive from distributed-process.

-}
module Control.Distributed.Process.Platform
  (
    -- * Exported Types
    Addressable(..)
  , NFSerializable
  , Recipient(..)
  , ExitReason(..)
  , Tag
  , TagPool

    -- * Primitives overriding those in distributed-process
  , module Control.Distributed.Process.Platform.UnsafePrimitives
  , monitor

    -- * Utilities and Extended Primitives
  , spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure
  , times
  , isProcessAlive
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

import Control.Distributed.Process (RemoteTable)
import Control.Distributed.Process.Platform.Internal.Types
  ( NFSerializable
  , Recipient(..)
  , ExitReason(..)
  , Tag
  , TagPool
  , newTagPool
  , getTag
  )
import Control.Distributed.Process.Platform.UnsafePrimitives
import Control.Distributed.Process.Platform.Internal.Primitives hiding (__remoteTable)
import qualified Control.Distributed.Process.Platform.Internal.Primitives (__remoteTable)
import qualified Control.Distributed.Process.Platform.Internal.Types      (__remoteTable)

-- remote table

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable =
   Control.Distributed.Process.Platform.Internal.Primitives.__remoteTable .
   Control.Distributed.Process.Platform.Internal.Types.__remoteTable
