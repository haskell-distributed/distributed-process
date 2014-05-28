{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RecordWildCards #-}

module Control.Distributed.Process.Management.Internal.Agent where

import Control.Applicative ((<$>))
import Control.Concurrent (forkIO)
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
import Control.Distributed.Process.Management.Internal.Types
  ( Fork
  )
import Control.Distributed.Process.Management.Internal.Trace.Tracer
  ( traceController
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , Message
  , Tracer(..)
  , LocalProcess(..)
  , ProcessId
  , forever'
  )
import Control.Exception (AsyncException(ThreadKilled), SomeException)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import GHC.Weak (Weak, deRefWeak)

--------------------------------------------------------------------------------
-- Agent Controller Implementation                                            --
--------------------------------------------------------------------------------

-- | A triple containing a configured tracer, weak pointer to the
-- agent controller's mailbox (CQueue) and an expression used to
-- instantiate new agents on the current node.
type AgentConfig =
  (Tracer, Weak (CQueue Message),
   (((TChan Message, TChan Message) -> Process ()) -> IO ProcessId))

-- | Starts a management agent for the current node. The agent process
-- must not crash or be killed, so we generally avoid publishing its
-- @ProcessId@ where possible.
--
-- Our process is also responsible for forwarding messages to the trace
-- controller, since having two /special processes/ handled via the
-- @LocalNode@ would be inelegant. We forward messages directly to the
-- trace controller's message queue, just as the @MxEventBus@ that's
-- set up on the @LocalNode@ forwards messages directly to us. This
-- optimises the code path for tracing and avoids overloading the node
-- node controller's internal control plane with additional routing, at the
-- cost of a little more complexity and two cases where we break
-- encapsulation.
--
mxAgentController :: Fork
                  -> MVar AgentConfig
                  -> Process ()
mxAgentController forkProcess mv = do
    trc <- liftIO $ startTracing forkProcess
    sigbus <- liftIO $ newBroadcastTChanIO
    liftIO $ startDeadLetterQueue sigbus
    weakQueue <- processWeakQ <$> ask
    liftIO $ putMVar mv (trc, weakQueue, mxStartAgent forkProcess sigbus)
    go sigbus trc
  where
    go bus tracer = forever' $ do
      void $ receiveWait [
          -- This is exactly what it appears to be: a "catch all" handler.
          -- Since mxNotify can potentially pass an unevaluated thunk to
          -- our mailbox, the dequeue (i.e., matchMessage) can fail and
          -- crash this process, which we DO NOT want. Alternatively,
          -- we handle IO exceptions here explicitly, since we don't want
          -- this process to ever crash, and the assumption we therefore
          -- make is thus:
          --
          -- 1. only ThreadKilled can tell this process to terminate
          -- 2. all other exceptions are invalid and should be ignored
          --
          -- The outcome of course, is that /bad/ calls to mxNotify
          -- (e.g., passing unevaluated thunks that will crash when
          -- they're eventually forced) are thus silently ignored.
          --
          matchAny (liftIO . broadcast bus tracer)
        ] `catches` [Handler (\ThreadKilled -> die "Killed"),
                     Handler (\(_ :: SomeException) -> return ())]

    broadcast :: TChan Message -> Tracer -> Message -> IO ()
    broadcast ch tr msg = do
      tmQueue <- tracerQueue tr
      atomicBroadcast ch tmQueue msg

    tracerQueue :: Tracer -> IO (Maybe (CQueue Message))
    tracerQueue (Tracer _ wQ) = deRefWeak wQ

    atomicBroadcast :: TChan Message
                    -> Maybe (CQueue Message)
                    -> Message -> IO ()
    atomicBroadcast ch Nothing  msg = liftIO $ atomically $ writeTChan ch msg
    atomicBroadcast ch (Just q) msg = do
      -- liftIO $ putStrLn $ "broadcasting " ++ (show msg)
      liftIO $ atomically $ enqueueSTM q msg >> writeTChan ch msg

-- | Forks a new process in which an mxAgent is run.
--
mxStartAgent :: Fork
             -> TChan Message
             -> ((TChan Message, TChan Message) -> Process ())
             -> IO ProcessId
mxStartAgent fork chan handler = do
  chan' <- atomically (dupTChan chan)
  let proc = handler (chan, chan')
  fork proc

-- | Start the tracer controller.
--
startTracing :: Fork -> IO Tracer
startTracing forkProcess = do
  mv  <- newEmptyMVar
  pid <- forkProcess $ traceController mv
  wQ  <- liftIO $ takeMVar mv
  return $ Tracer pid wQ

-- | Start a dead letter (agent) queue.
--
-- If no agents are registered on the system, the management
-- event bus will fill up and its data won't be GC'ed until someone
-- comes along and reads from the broadcast channel (via dupTChan
-- of course). This is effectively a leak, so to mitigate it, we
-- start a /dead letter queue/ that drains the event bus continuously,
-- thus ensuring if there are no other consumers that we won't use
-- up heap space unnecessarily.
--
startDeadLetterQueue :: TChan Message
                     -> IO ()
startDeadLetterQueue sigbus = do
  chan' <- atomically (dupTChan sigbus)
  void $ forkIO $ forever' $ do
    void $ atomically $ readTChan chan'
