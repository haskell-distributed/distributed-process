-- | Keeps the tracing API calls separate from the Tracer implementation,
-- which allows us to avoid a nasty import cycle between tracing and
-- the messaging primitives that rely on it
module Control.Distributed.Process.Internal.Trace.Primitives
  ( Tracer
  , TraceEvent(..)
    -- * Sending Trace Data
  , traceLog
  , traceLogFmt
  , traceEvent
  , traceMessage
    -- * Configuring A Tracer
  , defaultTraceFlags
  , enableTrace
  , disableTrace
  , setTraceFlags
  ) where

import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal.Trace.Types
  ( TraceArg(..)
  , TraceEvent(..)
  , SetTrace(..)
  , TraceFlags(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Internal.Types
  ( Tracer(..)
  , ProcessId
  , Message
  , createUnencodedMessage
  )
import Control.Distributed.Process.Serializable
import Data.Foldable (forM_)
import Data.List (intersperse)
import System.Mem.Weak (deRefWeak)

--------------------------------------------------------------------------------
-- Main API                                                                   --
--------------------------------------------------------------------------------

traceLog :: Tracer -> String -> IO ()
traceLog tr s = traceMessage tr (TraceEvLog s)

traceLogFmt :: Tracer
            -> String
            -> [TraceArg]
            -> IO ()
traceLogFmt t d ls =
  traceLog t $ concat (intersperse d (map toS ls))
  where toS :: TraceArg -> String
        toS (TraceStr s) = s
        toS (Trace    a) = show a

traceEvent :: Tracer -> TraceEvent -> IO ()
traceEvent tr ev = traceIt tr (createUnencodedMessage ev)

traceMessage :: Serializable m => Tracer -> m -> IO ()
traceMessage tr msg = traceEvent tr (TraceEvUser (createUnencodedMessage msg))

enableTrace :: Tracer -> ProcessId -> IO ()
enableTrace t p = traceIt t (createUnencodedMessage (TraceEnable p))

disableTrace :: Tracer -> IO ()
disableTrace t = traceIt t (createUnencodedMessage TraceDisable)

setTraceFlags :: Tracer -> TraceFlags -> IO ()
setTraceFlags t f = traceIt t (createUnencodedMessage f)

traceIt :: Tracer -> Message -> IO ()
traceIt InactiveTracer         _   = return ()
traceIt (ActiveTracer _ wqRef) msg = do
  mQueue <- deRefWeak wqRef
  forM_ mQueue $ \queue -> enqueue queue msg
  