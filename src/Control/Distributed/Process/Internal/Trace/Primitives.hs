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
  , enableTraceSync
  , disableTrace
  , disableTraceSync
  , getTraceFlags
  , setTraceFlags
  , setTraceFlagsSync
  , traceOnly
  , traceOn
  , traceOff
  ) where

import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal.Trace.Types
  ( TraceArg(..)
  , TraceEvent(..)
  , SetTrace(..)
  , TraceFlags(..)
  , TraceOk(..)
  , TraceSubject(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Internal.Types
  ( Tracer(..)
  , ProcessId
  , Message
  , SendPort
  , createUnencodedMessage
  )
import Control.Distributed.Process.Serializable
import Data.Foldable (forM_)
import Data.List (intersperse)
import qualified Data.Set as Set (fromList)
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
enableTrace t p =
  traceIt t (createUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     (TraceEnable p)))

enableTraceSync :: Tracer -> SendPort TraceOk -> ProcessId -> IO ()
enableTraceSync t s p =
  traceIt t (createUnencodedMessage ((Just s), (TraceEnable p)))

disableTrace :: Tracer -> IO ()
disableTrace t =
  traceIt t (createUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     TraceDisable))

disableTraceSync :: Tracer -> SendPort TraceOk -> IO ()
disableTraceSync t s =
  traceIt t (createUnencodedMessage ((Just s), TraceDisable))

setTraceFlags :: Tracer -> TraceFlags -> IO ()
setTraceFlags t f =
  traceIt t (createUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)), f))

setTraceFlagsSync :: Tracer -> SendPort TraceOk -> TraceFlags -> IO ()
setTraceFlagsSync t s f =
  traceIt t (createUnencodedMessage ((Just s), f))

getTraceFlags :: Tracer -> SendPort TraceFlags -> IO ()
getTraceFlags t s = traceIt t (createUnencodedMessage s)

-- aux API and utilities

class Traceable a where
  uod :: [a] -> TraceSubject

instance Traceable ProcessId where
  uod = TraceProcs . Set.fromList

instance Traceable String where
  uod = TraceNames . Set.fromList

traceOnly :: Traceable a => [a] -> Maybe TraceSubject
traceOnly = Just . uod

traceOn :: Maybe TraceSubject
traceOn = Just TraceAll

traceOff :: Maybe TraceSubject
traceOff = Nothing

traceIt :: Tracer -> Message -> IO ()
traceIt InactiveTracer         _   = return ()
traceIt (ActiveTracer _ wqRef) msg = do
  mQueue <- deRefWeak wqRef
  forM_ mQueue $ \queue -> enqueue queue msg

