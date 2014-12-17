{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.ManagedProcess.Server
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Server Portion of the /Managed Process/ API.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.ManagedProcess.Server
  ( -- * Server actions
    condition
  , state
  , input
  , reply
  , replyWith
  , noReply
  , continue
  , timeoutAfter
  , hibernate
  , stop
  , stopWith
  , replyTo
  , replyChan
    -- * Stateless actions
  , noReply_
  , haltNoReply_
  , continue_
  , timeoutAfter_
  , hibernate_
  , stop_
    -- * Server handler/callback creation
  , handleCall
  , handleCallIf
  , handleCallFrom
  , handleCallFromIf
  , handleRpcChan
  , handleRpcChanIf
  , handleCast
  , handleCastIf
  , handleInfo
  , handleRaw
  , handleDispatch
  , handleDispatchIf
  , handleExit
  , handleExitIf
    -- * Stateless handlers
  , action
  , handleCall_
  , handleCallIf_
  , handleCallFrom_
  , handleCallFromIf_
  , handleRpcChan_
  , handleRpcChanIf_
  , handleCast_
  , handleCastIf_
    -- * Working with Control Channels
  , handleControlChan
  , handleControlChan_
  ) where

import Control.Distributed.Process hiding (call, Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  , Routable(..)
  )
import Control.Distributed.Process.Platform.Time
import Prelude hiding (init)

--------------------------------------------------------------------------------
-- Producing ProcessAction and ProcessReply from inside handler expressions   --
--------------------------------------------------------------------------------

-- | Creates a 'Condition' from a function that takes a process state @a@ and
-- an input message @b@ and returns a 'Bool' indicating whether the associated
-- handler should run.
--
condition :: forall a b. (Serializable a, Serializable b)
          => (a -> b -> Bool)
          -> Condition a b
condition = Condition

-- | Create a 'Condition' from a function that takes a process state @a@ and
-- returns a 'Bool' indicating whether the associated handler should run.
--
state :: forall s m. (Serializable m) => (s -> Bool) -> Condition s m
state = State

-- | Creates a 'Condition' from a function that takes an input message @m@ and
-- returns a 'Bool' indicating whether the associated handler should run.
--
input :: forall s m. (Serializable m) => (m -> Bool) -> Condition s m
input = Input

-- | Instructs the process to send a reply and continue running.
reply :: (Serializable r) => r -> s -> Process (ProcessReply r s)
reply r s = continue s >>= replyWith r

-- | Instructs the process to send a reply /and/ evaluate the 'ProcessAction'.
replyWith :: (Serializable r)
          => r
          -> ProcessAction s
          -> Process (ProcessReply r s)
replyWith r s = return $ ProcessReply r s

-- | Instructs the process to skip sending a reply /and/ evaluate a 'ProcessAction'
noReply :: (Serializable r) => ProcessAction s -> Process (ProcessReply r s)
noReply = return . NoReply

-- | Continue without giving a reply to the caller - equivalent to 'continue',
-- but usable in a callback passed to the 'handleCall' family of functions.
noReply_ :: forall s r . (Serializable r) => s -> Process (ProcessReply r s)
noReply_ s = continue s >>= noReply

-- | Halt process execution during a call handler, without paying any attention
-- to the expected return type.
haltNoReply_ :: Serializable r => ExitReason -> Process (ProcessReply r s)
haltNoReply_ r = stop r >>= noReply

-- | Instructs the process to continue running and receiving messages.
continue :: s -> Process (ProcessAction s)
continue = return . ProcessContinue

-- | Version of 'continue' that can be used in handlers that ignore process state.
--
continue_ :: (s -> Process (ProcessAction s))
continue_ = return . ProcessContinue

-- | Instructs the process loop to wait for incoming messages until 'Delay'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @Delay@ will remain in use until changed.
timeoutAfter :: Delay -> s -> Process (ProcessAction s)
timeoutAfter d s = return $ ProcessTimeout d s

-- | Version of 'timeoutAfter' that can be used in handlers that ignore process state.
--
-- > action (\(TimeoutPlease duration) -> timeoutAfter_ duration)
--
timeoutAfter_ :: Delay -> (s -> Process (ProcessAction s))
timeoutAfter_ d = return . ProcessTimeout d

-- | Instructs the process to /hibernate/ for the given 'TimeInterval'. Note
-- that no messages will be removed from the mailbox until after hibernation has
-- ceased. This is equivalent to calling @threadDelay@.
--
hibernate :: TimeInterval -> s -> Process (ProcessAction s)
hibernate d s = return $ ProcessHibernate d s

-- | Version of 'hibernate' that can be used in handlers that ignore process state.
--
-- > action (\(HibernatePlease delay) -> hibernate_ delay)
--
hibernate_ :: TimeInterval -> (s -> Process (ProcessAction s))
hibernate_ d = return . ProcessHibernate d

-- | Instructs the process to terminate, giving the supplied reason. If a valid
-- 'shutdownHandler' is installed, it will be called with the 'ExitReason'
-- returned from this call, along with the process state.
stop :: ExitReason -> Process (ProcessAction s)
stop r = return $ ProcessStop r

-- | As 'stop', but provides an updated state for the shutdown handler.
stopWith :: s -> ExitReason -> Process (ProcessAction s)
stopWith s r = return $ ProcessStopping s r

-- | Version of 'stop' that can be used in handlers that ignore process state.
--
-- > action (\ClientError -> stop_ ExitNormal)
--
stop_ :: ExitReason -> (s -> Process (ProcessAction s))
stop_ r _ = stop r

-- | Sends a reply explicitly to a caller.
--
-- > replyTo = sendTo
--
replyTo :: (Serializable m) => CallRef m -> m -> Process ()
replyTo = sendTo

-- | Sends a reply to a 'SendPort' (for use in 'handleRpcChan' et al).
--
-- > replyChan = sendChan
--
replyChan :: (Serializable m) => SendPort m -> m -> Process ()
replyChan = sendChan

--------------------------------------------------------------------------------
-- Wrapping handler expressions in Dispatcher and DeferredDispatcher          --
--------------------------------------------------------------------------------

-- | Constructs a 'call' handler from a function in the 'Process' monad.
-- The handler expression returns the reply, and the action will be
-- set to 'continue'.
--
-- > handleCall_ = handleCallIf_ $ input (const True)
--
handleCall_ :: (Serializable a, Serializable b)
           => (a -> Process b)
           -> Dispatcher s
handleCall_ = handleCallIf_ $ input (const True)

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. This variant ignores the state argument present in 'handleCall' and
-- 'handleCallIf' and is therefore useful in a stateless server. Messges are
-- only dispatched to the handler if the supplied condition evaluates to @True@
--
-- See 'handleCall'
handleCallIf_ :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (a -> Process b) -- ^ a function from an input message to a reply
    -> Dispatcher s
handleCallIf_ cond handler
  = DispatchIf {
      dispatch   = doHandle handler
    , dispatchIf = checkCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (a -> Process b)
                 -> s
                 -> Message a b
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h p) >>= mkCallReply c s
        doHandle _ _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- note [Message type]

        -- handling 'reply-to' in the main process loop is awkward at best,
        -- so we handle it here instead and return the 'action' to the loop
        mkCallReply :: (Serializable b)
                    => CallRef b
                    -> s
                    -> b
                    -> Process (ProcessAction s)
        mkCallReply c s m =
          let (c', t) = unCaller c
          in sendTo c' (CallResponse m t) >> continue s

-- | Constructs a 'call' handler from a function in the 'Process' monad.
-- > handleCall = handleCallIf (const True)
--
handleCall :: (Serializable a, Serializable b)
           => (s -> a -> Process (ProcessReply b s))
           -> Dispatcher s
handleCall = handleCallIf $ state (const True)

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessReply b s))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@.
--
handleCallIf :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (s -> a -> Process (ProcessReply b s))
        -- ^ a reply yielding function over the process state and input message
    -> Dispatcher s
handleCallIf cond handler
  = DispatchIf {
      dispatch   = doHandle handler
    , dispatchIf = checkCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> a -> Process (ProcessReply b s))
                 -> s
                 -> Message a b
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s p) >>= mkReply c
        doHandle _ _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- note [Message type]

-- | A variant of 'handleCallFrom_' that ignores the state argument.
--
handleCallFrom_ :: forall s a b . (Serializable a, Serializable b)
                => (CallRef b -> a -> Process (ProcessReply b s))
                -> Dispatcher s
handleCallFrom_ = handleCallFromIf_ $ input (const True)

-- | A variant of 'handleCallFromIf' that ignores the state argument.
--
handleCallFromIf_ :: forall s a b . (Serializable a, Serializable b)
                  => (Condition s a)
                  -> (CallRef b -> a -> Process (ProcessReply b s))
                  -> Dispatcher s
handleCallFromIf_ c h =
  DispatchIf {
      dispatch   = doHandle h
    , dispatchIf = checkCall c
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (CallRef b -> a -> Process (ProcessReply b s))
                 -> s
                 -> Message a b
                 -> Process (ProcessAction s)
        doHandle h' _ (CallMessage p c') = (h' c' p) >>= mkReply c'
        doHandle _  _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- note [Message type]

-- | As 'handleCall' but passes the 'CallRef' to the handler function.
-- This can be useful if you wish to /reply later/ to the caller by, e.g.,
-- spawning a process to do some work and have it @replyTo caller response@
-- out of band. In this case the callback can pass the 'CallRef' to the
-- worker (or stash it away itself) and return 'noReply'.
--
handleCallFrom :: forall s a b . (Serializable a, Serializable b)
           => (s -> CallRef b -> a -> Process (ProcessReply b s))
           -> Dispatcher s
handleCallFrom = handleCallFromIf $ state (const True)

-- | As 'handleCallFrom' but only runs the handler if the supplied 'Condition'
-- evaluates to @True@.
--
handleCallFromIf :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (s -> CallRef b -> a -> Process (ProcessReply b s))
        -- ^ a reply yielding function over the process state, sender and input message
    -> Dispatcher s
handleCallFromIf cond handler
  = DispatchIf {
      dispatch   = doHandle handler
    , dispatchIf = checkCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> CallRef b -> a -> Process (ProcessReply b s))
                 -> s
                 -> Message a b
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s c p) >>= mkReply c
        doHandle _ _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- note [Message type]

-- | Creates a handler for a /typed channel/ RPC style interaction. The
-- handler takes a @SendPort b@ to reply to, the initial input and evaluates
-- to a 'ProcessAction'. It is the handler code's responsibility to send the
-- reply to the @SendPort@.
--
handleRpcChan :: forall s a b . (Serializable a, Serializable b)
              => (s -> SendPort b -> a -> Process (ProcessAction s))
              -> Dispatcher s
handleRpcChan = handleRpcChanIf $ input (const True)

-- | As 'handleRpcChan', but only evaluates the handler if the supplied
-- condition is met.
--
handleRpcChanIf :: forall s a b . (Serializable a, Serializable b)
                => Condition s a
                -> (s -> SendPort b -> a -> Process (ProcessAction s))
                -> Dispatcher s
handleRpcChanIf c h
  = DispatchIf {
      dispatch   = doHandle h
    , dispatchIf = checkRpc c
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> SendPort b -> a -> Process (ProcessAction s))
                 -> s
                 -> Message a b
                 -> Process (ProcessAction s)
        doHandle h' s (ChanMessage p c') = h' s c' p
        doHandle _  _ _ = die "RPC_HANDLER_TYPE_MISMATCH" -- node [Message type]

-- | A variant of 'handleRpcChan' that ignores the state argument.
--
handleRpcChan_ :: forall a b . (Serializable a, Serializable b)
                  => (SendPort b -> a -> Process (ProcessAction ()))
                  -> Dispatcher ()
handleRpcChan_ h = handleRpcChan (\() -> h)

-- | A variant of 'handleRpcChanIf' that ignores the state argument.
--
handleRpcChanIf_ :: forall a b . (Serializable a, Serializable b)
                 => Condition () a
                 -> (SendPort b -> a -> Process (ProcessAction ()))
                 -> Dispatcher ()
handleRpcChanIf_ c h = handleRpcChanIf c (\() -> h)

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad.
-- > handleCast = handleCastIf (const True)
--
handleCast :: (Serializable a)
           => (s -> a -> Process (ProcessAction s))
           -> Dispatcher s
handleCast = handleCastIf $ input (const True)

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessAction s))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/.
--
handleCastIf :: forall s a . (Serializable a)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (s -> a -> Process (ProcessAction s))
       -- ^ an action yielding function over the process state and input message
    -> Dispatcher s
handleCastIf cond h
  = DispatchIf {
      dispatch   = (\s ((CastMessage p) :: Message a ()) -> h s p)
    , dispatchIf = checkCast cond
    }

-- | Constructs a /control channel/ handler from a function in the
-- 'Process' monad. The handler expression returns no reply, and the
-- /control message/ is treated in the same fashion as a 'cast'.
--
-- > handleControlChan = handleControlChanIf $ input (const True)
--
handleControlChan :: forall s a . (Serializable a)
    => ControlChannel a -- ^ the receiving end of the control channel
    -> (s -> a -> Process (ProcessAction s))
       -- ^ an action yielding function over the process state and input message
    -> Dispatcher s
handleControlChan chan h
  = DispatchCC { channel  = snd $ unControl chan
               , dispatch = (\s ((CastMessage p) :: Message a ()) -> h s p)
               }

-- | Version of 'handleControlChan' that ignores the server state.
--
handleControlChan_ :: forall s a. (Serializable a)
           => ControlChannel a
           -> (a -> (s -> Process (ProcessAction s)))
           -> Dispatcher s
handleControlChan_ chan h
  = DispatchCC { channel    = snd $ unControl chan
               , dispatch   = (\s ((CastMessage p) :: Message a ()) -> h p $ s)
               }

-- | Version of 'handleCast' that ignores the server state.
--
handleCast_ :: (Serializable a)
            => (a -> (s -> Process (ProcessAction s))) -> Dispatcher s
handleCast_ = handleCastIf_ $ input (const True)

-- | Version of 'handleCastIf' that ignores the server state.
--
handleCastIf_ :: forall s a . (Serializable a)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (a -> (s -> Process (ProcessAction s)))
        -- ^ a function from the input message to a /stateless action/, cf 'continue_'
    -> Dispatcher s
handleCastIf_ cond h
  = DispatchIf { dispatch   = (\s ((CastMessage p) :: Message a ()) -> h p $ s)
               , dispatchIf = checkCast cond
               }

-- | Constructs an /action/ handler. Like 'handleDispatch' this can handle both
-- 'cast' and 'call' messages, but you won't know which you're dealing with.
-- This can be useful where certain inputs require a definite action, such as
-- stopping the server, without concern for the state (e.g., when stopping we
-- need only decide to stop, as the terminate handler can deal with state
-- cleanup etc). For example:
--
-- @action (\MyCriticalSignal -> stop_ ExitNormal)@
--
action :: forall s a . (Serializable a)
    => (a -> (s -> Process (ProcessAction s)))
          -- ^ a function from the input message to a /stateless action/, cf 'continue_'
    -> Dispatcher s
action h = handleDispatch perform
  where perform :: (s -> a -> Process (ProcessAction s))
        perform s a = let f = h a in f s

-- | Constructs a handler for both /call/ and /cast/ messages.
-- @handleDispatch = handleDispatchIf (const True)@
--
handleDispatch :: forall s a . (Serializable a)
               => (s -> a -> Process (ProcessAction s))
               -> Dispatcher s
handleDispatch = handleDispatchIf $ input (const True)

-- | Constructs a handler for both /call/ and /cast/ messages. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@.
-- Handlers defined in this way have no access to the call context (if one
-- exists) and cannot therefore reply to calls.
--
handleDispatchIf :: forall s a . (Serializable a)
                 => Condition s a
                 -> (s -> a -> Process (ProcessAction s))
                 -> Dispatcher s
handleDispatchIf cond handler = DispatchIf {
      dispatch = doHandle handler
    , dispatchIf = check cond
    }
  where doHandle :: (Serializable a)
                 => (s -> a -> Process (ProcessAction s))
                 -> s
                 -> Message a ()
                 -> Process (ProcessAction s)
        doHandle h s msg =
            case msg of
                (CallMessage p _) -> (h s p)
                (CastMessage p)   -> (h s p)
                (ChanMessage p _) -> (h s p)

-- | Creates a generic input handler (i.e., for received messages that are /not/
-- sent using the 'cast' or 'call' APIs) from an ordinary function in the
-- 'Process' monad.
handleInfo :: forall s a. (Serializable a)
           => (s -> a -> Process (ProcessAction s))
           -> DeferredDispatcher s
handleInfo h = DeferredDispatcher { dispatchInfo = doHandleInfo h }
  where
    doHandleInfo :: forall s2 a2. (Serializable a2)
                             => (s2 -> a2 -> Process (ProcessAction s2))
                             -> s2
                             -> P.Message
                             -> Process (Maybe (ProcessAction s2))
    doHandleInfo h' s msg = handleMessage msg (h' s)

-- | Handle completely /raw/ input messages.
--
handleRaw :: forall s. (s -> P.Message -> Process (ProcessAction s))
          -> DeferredDispatcher s
handleRaw h = DeferredDispatcher { dispatchInfo = doHandle h }
  where
    doHandle h' s msg = h' s msg >>= return . Just

-- | Creates an /exit handler/ scoped to the execution of any and all the
-- registered call, cast and info handlers for the process.
handleExit :: forall s a. (Serializable a)
           => (s -> ProcessId -> a -> Process (ProcessAction s))
           -> ExitSignalDispatcher s
handleExit h = ExitSignalDispatcher { dispatchExit = doHandleExit h }
  where
    doHandleExit :: (s -> ProcessId -> a -> Process (ProcessAction s))
                 -> s
                 -> ProcessId
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
    doHandleExit h' s p msg = handleMessage msg (h' s p)

handleExitIf :: forall s a . (Serializable a)
             => (s -> a -> Bool)
             -> (s -> ProcessId -> a -> Process (ProcessAction s))
             -> ExitSignalDispatcher s
handleExitIf c h = ExitSignalDispatcher { dispatchExit = doHandleExit c h }
  where
    doHandleExit :: (s -> a -> Bool)
                 -> (s -> ProcessId -> a -> Process (ProcessAction s))
                 -> s
                 -> ProcessId
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
    doHandleExit c' h' s p msg = handleMessageIf msg (c' s) (h' s p)

-- handling 'reply-to' in the main process loop is awkward at best,
-- so we handle it here instead and return the 'action' to the loop
mkReply :: (Serializable b)
        => CallRef b
        -> ProcessReply b s
        -> Process (ProcessAction s)
mkReply _ (NoReply a)         = return a
mkReply c (ProcessReply r' a) = sendTo c r' >> return a

-- these functions are the inverse of 'condition', 'state' and 'input'

check :: forall s m a . (Serializable m)
            => Condition s m
            -> s
            -> Message m a
            -> Bool
check (Condition c) st msg = c st $ decode msg
check (State     c) st _   = c st
check (Input     c) _  msg = c $ decode msg

checkRpc :: forall s m a . (Serializable m)
            => Condition s m
            -> s
            -> Message m a
            -> Bool
checkRpc cond st msg@(ChanMessage _ _) = check cond st msg
checkRpc _    _  _                     = False

checkCall :: forall s m a . (Serializable m)
             => Condition s m
             -> s
             -> Message m a
             -> Bool
checkCall cond st msg@(CallMessage _ _) = check cond st msg
checkCall _    _  _                     = False

checkCast :: forall s m . (Serializable m)
             => Condition s m
             -> s
             -> Message m ()
             -> Bool
checkCast cond st msg@(CastMessage _) = check cond st msg
checkCast _    _     _                = False

decode :: Message a b -> a
decode (CallMessage a _) = a
decode (CastMessage a)   = a
decode (ChanMessage a _) = a

