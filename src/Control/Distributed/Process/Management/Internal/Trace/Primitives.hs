{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE TypeSynonymInstances  #-}
-- | Keeps the tracing API calls separate from the Tracer implementation,
-- which allows us to avoid a nasty import cycle between tracing and
-- the messaging primitives that rely on it, and also between the node
-- controller (which requires access to the tracing related elements of
-- our RemoteTable) and the Debug module, which requires @forkProcess@.
-- This module is also used by the management agent, which relies on the
-- tracing infrastructure's messaging fabric.
module Control.Distributed.Process.Management.Internal.Trace.Primitives
  ( -- * Sending Trace Data
    traceLog
  , traceLogFmt
  , traceMessage
    -- * Configuring A Tracer
  , defaultTraceFlags
  , enableTrace
  , enableTraceAsync
  , disableTrace
  , disableTraceAsync
  , getTraceFlags
  , setTraceFlags
  , setTraceFlagsAsync
  , traceOnly
  , traceOn
  , traceOff
  , withLocalTracer
  , withRegisteredTracer
  ) where

import Control.Applicative ((<$>))
import Control.Distributed.Process.Internal.Primitives
  ( whereis
  , newChan
  , receiveChan
  )
import Control.Distributed.Process.Management.Internal.Trace.Types
  ( TraceArg(..)
  , TraceFlags(..)
  , TraceOk(..)
  , TraceSubject(..)
  , defaultTraceFlags
  )
import qualified Control.Distributed.Process.Management.Internal.Trace.Types as Tracer
  ( traceLog
  , traceLogFmt
  , traceMessage
  , enableTrace
  , enableTraceSync
  , disableTrace
  , disableTraceSync
  , setTraceFlags
  , setTraceFlagsSync
  , getTraceFlags
  , getCurrentTraceClient
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , LocalProcess(..)
  , LocalNode(localEventBus)
  , SendPort
  , MxEventBus(..)
  )
import Control.Distributed.Process.Serializable
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)

import qualified Data.Set as Set (fromList)

--------------------------------------------------------------------------------
-- Main API                                                                   --
--------------------------------------------------------------------------------

-- | Converts a list of identifiers (that can be
-- mapped to process ids), to a 'TraceSubject'.
class Traceable a where
  uod :: [a] -> TraceSubject

instance Traceable ProcessId where
  uod = TraceProcs . Set.fromList

instance Traceable String where
  uod = TraceNames . Set.fromList

-- | Turn tracing for for a subset of trace targets.
traceOnly :: Traceable a => [a] -> Maybe TraceSubject
traceOnly = Just . uod

-- | Trace all targets.
traceOn :: Maybe TraceSubject
traceOn = Just TraceAll

-- | Trace no targets.
traceOff :: Maybe TraceSubject
traceOff = Nothing

-- | Enable tracing to the supplied process.
enableTraceAsync :: ProcessId -> Process ()
enableTraceAsync pid = withLocalTracer $ \t -> liftIO $ Tracer.enableTrace t pid

-- TODO: refactor _Sync versions of trace configuration functions...

-- | Enable tracing to the supplied process and wait for a @TraceOk@
-- response from the trace coordinator process.
enableTrace :: ProcessId -> Process ()
enableTrace pid =
  withLocalTracerSync $ \t sp -> Tracer.enableTraceSync t sp pid

-- | Disable the currently configured trace.
disableTraceAsync :: Process ()
disableTraceAsync = withLocalTracer $ \t -> liftIO $ Tracer.disableTrace t

-- | Disable the currently configured trace and wait for a @TraceOk@
-- response from the trace coordinator process.
disableTrace :: Process ()
disableTrace =
  withLocalTracerSync $ \t sp -> Tracer.disableTraceSync t sp

getTraceFlags :: Process TraceFlags
getTraceFlags = do
  (sp, rp) <- newChan
  withLocalTracer $ \t -> liftIO $ Tracer.getTraceFlags t sp
  receiveChan rp

-- | Set the given flags for the current tracer.
setTraceFlagsAsync :: TraceFlags -> Process ()
setTraceFlagsAsync f = withLocalTracer $ \t -> liftIO $ Tracer.setTraceFlags t f

-- | Set the given flags for the current tracer and wait for a @TraceOk@
-- response from the trace coordinator process.
setTraceFlags :: TraceFlags -> Process ()
setTraceFlags f =
  withLocalTracerSync $ \t sp -> Tracer.setTraceFlagsSync t sp f

-- | Send a log message to the internal tracing facility. If tracing is
-- enabled, this will create a custom trace log event.
--
traceLog :: String -> Process ()
traceLog s = withLocalTracer $ \t -> liftIO $ Tracer.traceLog t s

-- | Send a log message to the internal tracing facility, using the given
-- list of printable 'TraceArg's interspersed with the preceding delimiter.
--
traceLogFmt :: String -> [TraceArg] -> Process ()
traceLogFmt d ls = withLocalTracer $ \t -> liftIO $ Tracer.traceLogFmt t d ls

-- | Send an arbitrary 'Message' to the tracer process.
traceMessage :: Serializable m => m -> Process ()
traceMessage msg = withLocalTracer $ \t -> liftIO $ Tracer.traceMessage t msg

withLocalTracer :: (MxEventBus -> Process ()) -> Process ()
withLocalTracer act = do
  node <- processNode <$> ask
  act (localEventBus node)

withLocalTracerSync :: (MxEventBus -> SendPort TraceOk -> IO ()) -> Process ()
withLocalTracerSync act = do
  (sp, rp) <- newChan
  withLocalTracer $ \t -> liftIO $ (act t sp)
  TraceOk <- receiveChan rp
  return ()

withRegisteredTracer :: (ProcessId -> Process a) -> Process a
withRegisteredTracer act = do
  (sp, rp) <- newChan
  withLocalTracer $ \t -> liftIO $ Tracer.getCurrentTraceClient t sp
  currentTracer <- receiveChan rp
  case currentTracer of
    Nothing  -> do { (Just p') <- whereis "tracer.initial"; act p' }
    (Just p) -> act p

