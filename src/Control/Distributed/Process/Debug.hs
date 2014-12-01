{-# LANGUAGE CPP  #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RankNTypes  #-}
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
-- Cloud Haskell provides a general purpose tracing mechanism, allowing a
-- user supplied /tracer process/ to receive messages when certain classes of
-- system events occur. It's possible to use this facility to aid in debugging
-- and/or perform other diagnostic tasks to a program at runtime.
--
-- [Enabling Tracing]
--
-- Throughout the lifecycle of a local node, the distributed-process runtime
-- generates /trace events/, describing internal runtime activities such as
-- the spawning and death of processes, message sending, delivery and so on.
-- See the 'MxEvent' type's documentation for a list of all the published
-- event types, which correspond directly to the types of /management/ events.
-- Users can additionally publish custom trace events in the form of
-- 'MxLog' log messages or pass custom (i.e., completely user defined)
-- event data using the 'traceMessage' function.
--
-- All published traces are forwarded to a /tracer process/, which can be
-- specified (and changed) at runtime using 'traceEnable'. Some pre-defined
-- tracer processes are provided for conveniently printing to stderr, a log file
-- or the GHC eventlog.
--
-- If a tracer process crashes, no attempt is made to restart it.
--
-- [Working with multiple tracer processes]
--
-- The tracing facility only ever writes to a single tracer process. This
-- invariant insulates the tracer controller and ensures a fast path for
-- handling all trace events. /This/ module provides facilities for layering
-- trace handlers using Cloud Haskell's built-in delegation primitives.
--
-- The 'startTracer' function wraps the registered @tracer@ process with the
-- supplied handler and also forwards trace events to the original tracer.
-- The corresponding 'stopTracer' function terminates tracer processes in
-- reverse of the order in which they were started, and re-registers the
-- previous tracer process.
--
-- [Built in tracers]
--
-- The built in tracers provide a simple /logging/ facility that writes trace
-- events out to either a log file, @stderr@ or the GHC eventlog. These tracers
-- can be configured using environment variables, or specified manually using
-- the 'traceEnable' function.
--
-- When a new local node is started, the contents of several environment
-- variables are checked to determine which default tracer process is selected.
-- If none of these variables is set, a no-op tracer process is installed,
-- which effectively ignores all trace messages. Note that in this case,
-- trace events are still generated and passed through the system.
-- Only one default tracer will be chosen - the first that contains a (valid)
-- value. These environment variables, in the order they're examined, are:
--
-- 1. @DISTRIBUTED_PROCESS_TRACE_FILE@
-- This is checked for a valid file path. If it exists and the file can be
-- opened for writing, all trace output will be directed thence. If the supplied
-- path is invalid, or the file is unavailable for writing, this tracer will not
-- be selected.
--
-- 2. @DISTRIBUTED_PROCESS_TRACE_CONSOLE@
-- This is checked for /any/ non-empty value. If set, then all trace output will
-- be directed to the system logger process.
--
-- 3. @DISTRIBUTED_PROCESS_TRACE_EVENTLOG@
-- This is checked for /any/ non-empty value. If set, all internal traces are
-- written to the GHC eventlog.
--
-- By default, the built in tracers will ignore all trace events! In order to
-- enable tracing the incoming 'MxEvent' stream, the @DISTRIBUTED_PROCESS_TRACE_FLAGS@
-- environment variable accepts the following flags, which enable tracing specific
-- event types:
--
-- p  = trace the spawning of new processes
-- d  = trace the death of processes
-- n  = trace registration of names (i.e., named processes)
-- u  = trace un-registration of names (i.e., named processes)
-- s  = trace the sending of messages to other processes
-- r  = trace the receipt of messages from other processes
-- l  = trace node up/down events
--
-- Users of the /simplelocalnet/ Cloud Haskell backend should also note that
-- because the trace file option only supports trace output from a single node
-- (so as to avoid interleaving), a file trace configured for the master node
-- will prevent slaves from tracing to the file. They will need to fall back to
-- the console or eventlog tracers instead, which can be accomplished by setting
-- one of these environment variables /as well/, since the latter will only be
-- selected on slaves (when the file tracer selection fails).
--
-- Support for writing to the eventlog requires specific intervention to work,
-- without which, written traces are silently dropped/ignored and no output will
-- be generated. The GHC eventlog documentation provides information about
-- enabling, viewing and working with event traces at
-- <http://hackage.haskell.org/trac/ghc/wiki/EventLog>.
--
module Control.Distributed.Process.Debug
  ( -- * Exported Data Types
    TraceArg(..)
  , TraceFlags(..)
  , TraceSubject(..)
    -- * Configuring Tracing
  , enableTrace
  , enableTraceAsync
  , disableTrace
  , withTracer
  , withFlags
  , getTraceFlags
  , setTraceFlags
  , setTraceFlagsAsync
  , defaultTraceFlags
  , traceOn
  , traceOnly
  , traceOff
    -- * Debugging
  , startTracer
  , stopTracer
    -- * Sending Custom Trace Data
  , traceLog
  , traceLogFmt
  , traceMessage
    -- * Working with remote nodes
  , Remote.remoteTable
  , Remote.startTraceRelay
  , Remote.setTraceFlagsRemote
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
  , whereis
  , send
  , receiveWait
  , matchIf
  , finally
  , try
  , monitor
  )
import Control.Distributed.Process.Internal.Types
  ( ProcessId
  , Process
  , LocalProcess(..)
  , ProcessMonitorNotification(..)
  )
import Control.Distributed.Process.Management.Internal.Types
  ( MxEvent(..)
  )
import Control.Distributed.Process.Management.Internal.Trace.Types
  ( TraceArg(..)
  , TraceFlags(..)
  , TraceSubject(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Management.Internal.Trace.Tracer
  ( systemLoggerTracer
  , logfileTracer
  , eventLogTracer
  )
import Control.Distributed.Process.Management.Internal.Trace.Primitives
  ( withRegisteredTracer
  , enableTrace
  , enableTraceAsync
  , disableTrace
  , setTraceFlags
  , setTraceFlagsAsync
  , getTraceFlags
  , traceOn
  , traceOff
  , traceOnly
  , traceLog
  , traceLogFmt
  , traceMessage
  )
import qualified Control.Distributed.Process.Management.Internal.Trace.Remote as Remote
import Control.Distributed.Process.Node

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
-- through all the layers in turn. Once the top layer is stopped, the user
-- is responsible for re-registering the original (prior) tracer pid before
-- terminating. See 'withTracer' for a mechanism that handles that.
startTracer :: (MxEvent -> Process ()) -> Process ProcessId
startTracer handler = do
  withRegisteredTracer $ \pid -> do
    node <- processNode <$> ask
    newPid <- liftIO $ forkProcess node $ traceProxy pid handler
    enableTrace newPid  -- invokes sync + registration
    return newPid

-- | Evaluate @proc@ with tracing enabled via @handler@, and immediately
-- disable tracing thereafter, before giving the result (or exception
-- in case of failure).
withTracer :: forall a.
              (MxEvent -> Process ())
           -> Process a
           -> Process (Either SomeException a)
withTracer handler proc = do
    previous <- whereis "tracer"
    tracer <- startTracer handler
    finally (try proc)
            (stopTracing tracer previous)
  where
    stopTracing :: ProcessId -> Maybe ProcessId -> Process ()
    stopTracing tracer previousTracer = do
      case previousTracer of
        Nothing -> return ()
        Just _  -> do
          ref <- monitor tracer
          send tracer MxTraceDisable
          receiveWait [
              matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                      (\_ -> return ())
            ]

-- | Evaluate @proc@ with the supplied flags enabled. Any previously set
-- trace flags are restored immediately afterwards.
withFlags :: forall a.
             TraceFlags
          -> Process a
          -> Process (Either SomeException a)
withFlags flags proc = do
  oldFlags <- getTraceFlags
  finally (setTraceFlags flags >> try proc)
          (setTraceFlags oldFlags)

traceProxy :: ProcessId -> (MxEvent -> Process ()) -> Process ()
traceProxy pid act = do
  proxy pid $ \(ev :: MxEvent) ->
    case ev of
      (MxTraceTakeover _) -> return False
      MxTraceDisable      -> die "disabled"
      _                   -> act ev >> return True

-- | Stops a user supplied tracer started with 'startTracer'.
-- Note that only one tracer process can be active at any given time.
-- This process will stop the last process started with 'startTracer'.
-- If 'startTracer' is called multiple times, successive calls to this
-- function will stop the tracers in the reverse order which they were
-- started.
--
-- This function will never stop the system tracer (i.e., the tracer
-- initially started when the node is created), therefore once all user
-- supplied tracers (i.e., processes started via 'startTracer') have exited,
-- subsequent calls to this function will have no effect.
--
-- If the last tracer to have been registered was not started
-- with 'startTracer' then the behaviour of this function is /undefined/.
stopTracer :: Process ()
stopTracer =
  withRegisteredTracer $ \pid -> do
    -- we need to avoid killing the initial (base) tracer, as
    -- nothing we rely on having exactly 1 registered tracer
    -- process at all times.
    basePid <- whereis "tracer.initial"
    case basePid == (Just pid) of
      True  -> return ()
      False -> send pid MxTraceDisable
