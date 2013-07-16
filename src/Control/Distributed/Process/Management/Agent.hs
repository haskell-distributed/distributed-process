{-# LANGUAGE RecordWildCards #-}

module Control.Distributed.Process.Management.Agent where

import Control.Applicative ((<$>))
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
  ( TChan
  , newBroadcastTChanIO
  , readTChan
  , writeTChan
  , dupTChan
  )
import Control.Distributed.Process.Internal.Primitives
  ( receiveWait
  , matchAny
  , die
  , catches
  , Handler(..)
  )
import Control.Distributed.Process.Internal.CQueue
  ( enqueueSTM
  , CQueue
  )
import Control.Distributed.Process.Internal.Trace.Tracer
  ( traceController
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , SendPort
  , Message
  , MxEventBus(..)
  , Tracer(..)
  , LocalNode(..)
  , LocalProcess(..)
  , ProcessId
  , forever'
  )
import Control.Exception (AsyncException(ThreadKilled), SomeException)
import qualified Control.Exception as Ex (catch, finally)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import GHC.Weak (Weak(Weak), deRefWeak)
import System.Environment (getEnv)

-- | Gross though it is, this synonym represents a function
-- used to forking new processes, which has to be passed as a HOF
-- when calling mxAgentController, since there's no other way to
-- avoid a circular dependency with Node.hs
type Fork = (Process () -> IO ProcessId)

-- | A triple containing a configured tracer, weak pointer to the
-- agent controller's mailbox (CQueue) and an expression used to
-- instantiate new agents on the current node.
type AgentConfig =
  (Tracer, Weak (CQueue Message), ((Message -> Process ()) -> IO ProcessId))

-- | Starts a management agent for the current node. The agent process
-- must not crash or be killed, so we generally avoid publishing its
-- 'ProcessId' where possible.
--
-- Our process is also responsible for forwarding messages to the trace
-- controller, since having two /special processes/ handled via the
-- @LocalNode@ would be inelegant. We forward messages directly to the
-- trace controller's message queue, just as the @MxEventBus@ that's
-- set up on the @LocalNode@ forwards messages directly to us. This
-- also optimises the code path for tracing and avoids overloading the
-- node controller with additional routing, at the cost of a little
-- more complexity for us here.
--
mxAgentController :: Fork
                  -> MVar AgentConfig
                  -> Process ()
mxAgentController forkProcess mv = do
    node <- processNode <$> ask
    trc <- liftIO $ startTracing forkProcess node
    sigbus <- liftIO $ newBroadcastTChanIO
    weakQueue <- processWeakQ <$> ask
    liftIO $ putMVar mv (trc, weakQueue, mxAgent forkProcess sigbus)
    go sigbus trc forkProcess
  where
    go bus tracer fork = forever' $ do
      void $ receiveWait [
          -- This is exactly what it appears to be: a "catch all" handler.
          -- Since mxNotify can potentially pass an unevaluated thunk to
          -- our mailbox, the dequeue (i.e., matchMessage) can fail and
          -- crash this process, which we DO NOT want. Alternatively,
          -- we handle IO exceptions here explicitly, since we don't want
          -- this process to every crash, and the assumption we therefore
          -- make is thus:
          --
          -- 1. only ThreadKilled can tell this thread to terminate
          -- 2. all other exceptions are invalid and should be ignored
          --
          -- The outcome of course, is that /bad/ calls to mxNotify will
          -- be silently ignored.
          --
          matchAny (\msg -> liftIO $ broadcast bus tracer msg)
        ] `catches` [Handler (\ThreadKilled -> die "Killed"),
                     Handler (\(_ :: SomeException) -> return ())]

    broadcast :: TChan Message -> Tracer -> Message -> IO ()
    broadcast ch tr msg = do
      tmQueue <- tracerQueue tr
      atomicBroadcast ch tmQueue msg

    tracerQueue :: Tracer -> IO (Maybe (CQueue Message))
    tracerQueue InactiveTracer      = return Nothing
    tracerQueue (ActiveTracer _ wQ) = deRefWeak wQ

    atomicBroadcast :: TChan Message
                    -> Maybe (CQueue Message)
                    -> Message -> IO ()
    atomicBroadcast ch Nothing  msg = liftIO $ atomically $ writeTChan ch msg
    atomicBroadcast ch (Just q) msg = do
      liftIO $ atomically $ enqueueSTM q msg >> writeTChan ch msg

-- | Forks a new process in which an mxAgent is run.
mxAgent :: Fork -> TChan Message -> (Message -> Process ()) -> IO ProcessId
mxAgent fork chan handler = (atomically (dupTChan chan)) >>= fork . run handler
  where
    run :: (Message -> Process ()) -> TChan Message -> Process ()
    run handler' chan' = do
      (liftIO $ atomically $ readTChan chan') >>= handler' >> run handler' chan'

startTracing :: Fork -> LocalNode -> IO Tracer
startTracing forkProcess node =
  -- TODO: use tryGetEnv once we drop support for GHC 7.2.x
  Ex.catch
        (getEnv "DISTRIBUTED_PROCESS_TRACE_ENABLED" >> startTracing' forkProcess node)
        (\(_ :: IOError) -> return InactiveTracer)
  where
    startTracing' :: Fork -> LocalNode -> IO Tracer
    startTracing' fork' n = do
      mv  <- newEmptyMVar
      pid <- fork' $ traceController mv
      wQ  <- liftIO $ takeMVar mv
      return $ ActiveTracer pid wQ

