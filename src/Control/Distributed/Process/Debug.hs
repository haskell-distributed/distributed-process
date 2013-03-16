-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Debug
-- Copyright   :  (c) Well-Typed / Tim Watson
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- [Tracing/Debugging Facilities]
--
-- Cloud Haskell provides a general purpose tracing mechanism that allows a
-- user supplied /tracer process/ to receive messages when certain events
-- take place. It's possible to use this facility to debug a running system
-- and/or generate runtime monitoring data in a variety of formats.
--
-- [Enabling Tracing]
--
-- Tracing is disabled by default, because it carries a (relatively small, but
-- real) cost at runtime. To enable any kind of tracing to work, the environment
-- variable @DISTRIBUTED_PROCESS_TRACE_ENABLED@ must be set (the contents are
-- ignored). When the environment variable /is/ set, the system will generate
-- a /trace events/ in various circumstances - see 'TraceEvent' for a list of
-- all the published events. A user can additionally publish custom trace events
-- in the form of 'TraceEvLog' log messages or pass custom (i.e., completely
-- user defined) event data using the 'traceMessage' function. If the
-- environment variable is not set, no trace events will ever be published.
--
-- All published trace events are forwarded to a /tracer process/, which can be
-- specified (and changed) at runtime using 'traceEnable'. Some pre-defined
-- tracer processes are provided for conveniently printing to stderr, a log file
-- or the GHC eventlog.
--
-- If a tracer process crashes, no attempt is made to restart it.
--
-- [Working with multiple tracer processes]
--
-- The system tracing facility only ever writes to a single tracer process. This
-- invariant insulates the tracer controller and ensures a fast path for
-- handling all trace events. /This/ module provides facilities for layering
-- trace handlers using Cloud Haskell's built-in delegation primitives.
--
-- The 'startTracer' function wraps the registered @tracer@ process with the
-- supplied handler, forwarding trace events to the original tracer. The
-- corresponding 'stopTracer' function terminates tracer processes in reverse
-- of the order in which they were started.
--
-- [Built in tracers]
--
-- The built in tracers provide a simple /logging/ facility that writes trace
-- events out to either a log file, @stderr@ or the GHC eventlog. These tracers
-- can be configured using environment variables, or specified manually using
-- the 'traceEnable' function. The base tracer process cannot be
--
-- When a new local node is started, the contents of the environment variable
-- @DISTRIBUTED_PROCESS_TRACE_FILE@ are checked for a valid file path. If this
-- exists and the file can be opened for writing, all trace output will be
-- directed thence. If the environment variable is empty, the path invalid, or
-- the file is unavailable for writing - e.g., because another node has already
-- started tracing to it - then the @DISTRIBUTED_PROCESS_TRACE_CONSOLE@
-- environment variable is checked for /any/ non-empty value. If this is set,
-- then all trace output will be directed to the system logger process. If
-- neither variable provides a valid trace configuration, all internal traces
-- are written to "Debug.Trace.traceEventIO", which writes to the GHC eventlog.
--
-- Users of the /simplelocalnet/ Cloud Haskell backend should also note that
-- because the trace file option only supports trace output from a single node
-- (so as to avoid interleaving), a file trace configured for the master node
-- will prevent slaves from tracing to the file and they will fall back to using
-- the console or eventlog tracers instead.
--
-- Just as with the "Debug.Trace" module, this is a debugging/tracing facility
-- for use in development, and probably not best used in a production setting -
-- which is why the default behaviour is to trace to the GHC eventlog. For a
-- general purpose logging facility, you should consider 'say'.
--
-- Support for writing to the eventlog requires specific intervention to work,
-- without which traces are silently dropped/ignored and no output will be
-- generated. The GHC eventlog documentation provides information about enabling,
-- viewing and working with event traces at
-- <http://hackage.haskell.org/trac/ghc/wiki/EventLog>.
--
module Control.Distributed.Process.Debug
  ( -- * Exported Data Types
    TraceArg(..)
  , TraceEvent(..)
  , TraceFlags(..)
  , TraceSubject(..)
    -- * Configuring Tracing
  , isTracingEnabled
  , enableTrace
  , enableTraceAsync
  , disableTrace
  , disableTraceAsync
  , withTracer
  , setTraceFlags
  , setTraceFlagsAsync
  , defaultTraceFlags
    -- * Debugging
  , startTracer
  , stopTracer
    -- * Sending Trace Data
  , traceLog
  , traceLogFmt
  , traceMessage
    -- * Built in tracers
  , systemLoggerTracer
  , logfileTracer
  , eventLogTracer
  )
  where

import Control.Applicative ((<$>))
import Control.Distributed.Process.Internal.Primitives
  ( proxy
  , finally
  , die
  , getSelfPid
  , reregister
  , whereis
  , send
  , newChan
  , sendChan
  , receiveChan
  , receiveWait
  , matchIf
  , finally
  , try
  , monitor
  )
import Control.Distributed.Process.Internal.Types
  ( Tracer(..)
  , LocalNode(..)
  , ProcessId
  , Process
  , LocalProcess(..)
  , SendPort(..)
  , ProcessMonitorNotification(..)
  )
import Control.Distributed.Process.Internal.Trace.Types
  ( TraceArg(..)
  , TraceEvent(..)
  , TraceFlags(..)
  , TraceSubject(..)
  , TraceOk(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Internal.Trace.Tracer
  ( systemLoggerTracer
  , logfileTracer
  , eventLogTracer
  )
import qualified Control.Distributed.Process.Internal.Trace.Primitives as Tracer
  ( traceLog
  , traceLogFmt
  , traceMessage
  , enableTrace
  , enableTraceSync
  , disableTrace
  , disableTraceSync
  , setTraceFlags
  , setTraceFlagsSync
  )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable

import Control.Exception (SomeException)

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)

import Data.Binary()

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif


--------------------------------------------------------------------------------
-- Debugging/Tracing API                                                      --
--------------------------------------------------------------------------------

-- | Starts a new tracer, using the supplied trace function.
-- Only one tracer can be registered at a time, however /this/ function overlays
-- the registered tracer with the supplied handler, allowing the user to layer
-- multiple tracers on top of one another, with trace events forwarded down
-- through all the layers in turn. Once the top layer is stopped, it will
-- reregister the original (prior) tracer pid before terminating.
startTracer :: (TraceEvent -> Process ()) -> Process ProcessId
startTracer handler = do
  (sp, rp) <- newChan
  withRegisteredTracer $ \pid -> do
    node <- processNode <$> ask
    newPid <- liftIO $ forkProcess node $ do
        -- TODO: we ensure that the original
        -- tracer is re-registered, but it is
        -- possible this could lead to races
        -- if multiple tracers crash in very
        -- close succession, due to scheduling
        finally (traceProxy pid handler)
                (resetTracer pid)
    enableTrace newPid
    sendChan sp newPid
  receiveChan rp

-- | Evaluate @proc@ with tracing enabled via @handler@, and immediately
-- disable tracing thereafter, before giving the result (or exception
-- in case of failure).
withTracer :: forall a.
              (TraceEvent -> Process ())
           -> Process a
           -> Process (Either SomeException a)
withTracer handler proc = do
    tracer <- startTracer handler
    finally (try proc)
            (stopTracing tracer)
  where
    stopTracing :: ProcessId -> Process ()
    stopTracing tracer = do
      ref <- monitor tracer
      stopTracer
      receiveWait [
          matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                  (\_ -> return ())
        ]

traceProxy :: ProcessId -> (TraceEvent -> Process ()) -> Process ()
traceProxy pid act = do
  getSelfPid >>= reregister "tracer"  -- registration is synchronous
  proxy pid $ \(ev :: TraceEvent) ->
    case ev of
      (TraceEvTakeover _) -> die "takeover"
      TraceEvDisable      -> die "disabled"
      _                   -> act ev >> return True

resetTracer :: ProcessId -> Process ()
resetTracer pid = enableTrace pid

-- | Stops a user supplied tracer started with 'startTracer'.
-- Note that only one tracer process can be active at any given time.
-- This process will stop the last process started with 'startTracer'.
-- If 'startTracer' is called multiple times, successive calls to this
-- function will stop the tracers in the reverse order in which they were
-- started.
--
-- This function will never stop the system tracer (i.e., the tracer
-- initially started when the node is created), therefore once all user
-- supplied tracers (i.e., processes started via 'startTracer') have exited,
-- subsequent calls to this function will have no effect.
--
-- If tracing is support disabled for the node, this function will also
-- have no effect.
stopTracer :: Process ()
stopTracer = withLocalTracer $ \t ->
  case t of
    InactiveTracer -> return ()
    (ActiveTracer _ _) -> withRegisteredTracer $ \pid -> do
      -- we need to avoid killing the initial (base) tracer, as
      -- nothing we rely on having exactly 1 registered tracer
      -- process at all times!
      basePid <- whereis "tracer.initial"
      case basePid == (Just pid) of
        True  -> return ()
        False -> send pid TraceEvDisable

withRegisteredTracer :: (ProcessId -> Process ()) -> Process ()
withRegisteredTracer act = do
  currentTracer <- whereis "tracer"
  case currentTracer of
    Nothing  -> do { (Just p') <- whereis "tracer.initial"; act p' }
    (Just p) -> act p

-- | Determine whether or not tracing has been enabled.
isTracingEnabled :: Process Bool
isTracingEnabled = do
  node <- processNode <$> ask
  case (localTracer node) of
    (ActiveTracer _ _) -> return True
    _                  -> return False

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

-- | Set the given flags for the current tracer.
setTraceFlagsAsync :: TraceFlags -> Process ()
setTraceFlagsAsync f = withLocalTracer $ \t -> liftIO $ Tracer.setTraceFlags t f

-- | Set the given flags for the current tracer and wait for a @TraceOk@
-- response from the trace coordinator process.
setTraceFlags :: TraceFlags -> Process ()
setTraceFlags f =
  withLocalTracerSync $ \t sp -> Tracer.setTraceFlagsSync t sp f

withLocalTracerSync :: (Tracer -> SendPort TraceOk -> IO ()) -> Process ()
withLocalTracerSync act = do
  (sp, rp) <- newChan
  withLocalTracer $ \t -> liftIO $ (act t sp)
  TraceOk <- receiveChan rp
  return ()

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

withLocalTracer :: (Tracer -> Process ()) -> Process ()
withLocalTracer act = do
  node <- processNode <$> ask
  act (localTracer node)

