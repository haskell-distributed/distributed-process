module Control.Distributed.Process.Internal.Trace.Remote
  ( -- * Configuring A Tracer
    setTraceFlagsRemote
  , startTraceRelay
    -- * Remote Table
  , remoteTable
  ) where

import Control.Applicative ((<$>))
import Control.Distributed.Process.Internal.Closure.BuiltIn
  ( cpEnableTraceRemote
  )
import Control.Distributed.Process.Internal.Primitives
  ( proxy
  , finally
  , die
  , whereis
  , send
  , newChan
  , receiveChan
  , receiveWait
  , matchIf
  , finally
  , try
  , monitor
  , getSelfPid
  , relay
  , nsendRemote
  , say
  )
import Control.Distributed.Process.Internal.Trace.Types
  ( TraceFlags(..)
  , TraceOk(..)
  , TraceSubject(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Internal.Trace.Primitives
  ( withRegisteredTracer
  , enableTrace
  )
import Control.Distributed.Process.Internal.Spawn
  ( spawn
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , SendPort
  , NodeId
  )
import Control.Distributed.Process.Serializable
import Control.Distributed.Static
  ( RemoteTable
  , registerStatic
  )
import Data.Rank1Dynamic (toDynamic)
import qualified Data.Set as Set (fromList)

-- | Remote Table.
remoteTable :: RemoteTable -> RemoteTable
remoteTable = registerStatic "$enableTraceRemote" (toDynamic enableTraceRemote)

enableTraceRemote :: ProcessId -> Process ()
enableTraceRemote pid =
  getSelfPid >>= enableTrace >> relay pid

-- | Starts a /trace relay/ process on the remote node, that forwards all trace
-- events to the registered tracer on /this/ (the calling process') node.
startTraceRelay :: NodeId -> Process ProcessId
startTraceRelay nodeId = do
  withRegisteredTracer $ \pid ->
    -- TODO: move cpEnableTraceRemote here?
    spawn nodeId $ cpEnableTraceRemote pid

-- | Set the given flags for a remote node (asynchronous).
setTraceFlagsRemote :: TraceFlags -> NodeId -> Process ()
setTraceFlagsRemote flags node = do
  nsendRemote node
              "trace.controller"
              ((Nothing :: Maybe (SendPort TraceOk)), flags)

