{-# LANGUAGE StaticPointers #-}
module Control.Distributed.Process.Management.Internal.Trace.Remote
  ( -- * Configuring A Remote Tracer
    setTraceFlagsRemote
  , startTraceRelay
  ) where

import Control.Distributed.Process.Internal.Primitives
  ( getSelfPid
  , relay
  , nsendRemote
  )
import Control.Distributed.Process.Management.Internal.Trace.Types
  ( TraceFlags(..)
  , TraceOk(..)
  )
import Control.Distributed.Process.Management.Internal.Trace.Primitives
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
import Control.Distributed.Static
  ( Closure
  , closure
  )
import Data.Binary (decode, encode)

cpEnableTraceRemote :: ProcessId -> Closure (Process ())
cpEnableTraceRemote = closure (static (enableTraceRemote . decode)) . encode

enableTraceRemote :: ProcessId -> Process ()
enableTraceRemote pid =
  getSelfPid >>= enableTrace >> relay pid

-- | Starts a /trace relay/ process on the remote node, which forwards all trace
-- events to the registered tracer on /this/ (the calling process') node.
startTraceRelay :: NodeId -> Process ProcessId
startTraceRelay nodeId = do
  withRegisteredTracer $ \pid ->
    spawn nodeId $ cpEnableTraceRemote pid

-- | Set the given flags for a remote node (asynchronous).
setTraceFlagsRemote :: TraceFlags -> NodeId -> Process ()
setTraceFlagsRemote flags node = do
  nsendRemote node
              "trace.controller"
              ((Nothing :: Maybe (SendPort TraceOk)), flags)

