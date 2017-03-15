{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.ManagedProcess.Server
-- Copyright   :  (c) Tim Watson 2012 - 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Server Portion of the /Managed Process/ API.
-----------------------------------------------------------------------------

module Control.Distributed.Process.ManagedProcess.Server
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
  , reject
  , rejectWith
  , become
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
    -- * Working with external/STM actions
  , handleExternal
  , handleExternal_
  , handleCallExternal
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Distributed.Process hiding (call, Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.ManagedProcess.Internal.Types hiding (liftIO, lift)
import Control.Distributed.Process.Extras
  ( ExitReason(..)
  , Routable(..)
  )
import Control.Distributed.Process.Extras.Time
import Prelude hiding (init)

--------------------------------------------------------------------------------
-- Producing ProcessAction and ProcessReply from inside handler expressions   --
--------------------------------------------------------------------------------

-- note [Message type]: Since we own both client and server portions of the
-- codebase, we know for certain which types will be passed to which kinds
-- of handler, so the catch-all cases that @die $ "THIS_CAN_NEVER_HAPPEN"@ and
-- such, are relatively sane despite appearances!

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

-- | Reject the message we're currently handling.
reject :: forall r s . s -> String -> Reply r s
reject st rs = continue st >>= return . ProcessReject rs

-- | Reject the message we're currently handling, giving an explicit reason.
rejectWith :: forall r m s . (Show r) => s -> r -> Reply m s
rejectWith st rs = reject st (show rs)

-- | Instructs the process to send a reply and continue running.
reply :: (Serializable r) => r -> s -> Reply r s
reply r s = continue s >>= replyWith r

-- | Instructs the process to send a reply /and/ evaluate the 'ProcessAction'.
replyWith :: (Serializable r)
          => r
          -> ProcessAction s
          -> Reply r s
replyWith r s = return $ ProcessReply r s

-- | Instructs the process to skip sending a reply /and/ evaluate a 'ProcessAction'
noReply :: (Serializable r) => ProcessAction s -> Reply r s
noReply = return . NoReply

-- | Continue without giving a reply to the caller - equivalent to 'continue',
-- but usable in a callback passed to the 'handleCall' family of functions.
noReply_ :: forall s r . (Serializable r) => s -> Reply r s
noReply_ s = continue s >>= noReply

-- | Halt process execution during a call handler, without paying any attention
-- to the expected return type.
haltNoReply_ :: Serializable r => ExitReason -> Reply r s
haltNoReply_ r = stop r >>= noReply

-- | Instructs the process to continue running and receiving messages.
continue :: s -> Action s
continue = return . ProcessContinue

-- | Version of 'continue' that can be used in handlers that ignore process state.
--
continue_ :: (s -> Action s)
continue_ = return . ProcessContinue

-- | Instructs the process loop to wait for incoming messages until 'Delay'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @Delay@ will remain in use until changed.
--
-- Note that @timeoutAfter NoDelay@ will cause the timeout handler to execute
-- immediately if no messages are present in the process' mailbox.
--
timeoutAfter :: Delay -> s -> Action s
timeoutAfter d s = return $ ProcessTimeout d s

-- | Version of 'timeoutAfter' that can be used in handlers that ignore process state.
--
-- > action (\(TimeoutPlease duration) -> timeoutAfter_ duration)
--
timeoutAfter_ :: StatelessHandler s Delay
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
hibernate_ :: StatelessHandler s TimeInterval
hibernate_ d = return . ProcessHibernate d

become :: forall s . ProcessDefinition s -> s -> Action s
become def st = return $ ProcessBecome def st

-- | Instructs the process to terminate, giving the supplied reason. If a valid
-- 'shutdownHandler' is installed, it will be called with the 'ExitReason'
-- returned from this call, along with the process state.
stop :: ExitReason -> Action s
stop r = return $ ProcessStop r

-- | As 'stop', but provides an updated state for the shutdown handler.
stopWith :: s -> ExitReason -> Action s
stopWith s r = return $ ProcessStopping s r

-- | Version of 'stop' that can be used in handlers that ignore process state.
--
-- > action (\ClientError -> stop_ ExitNormal)
--
stop_ :: StatelessHandler s ExitReason
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
      dispatch   = \s (CallMessage p c) -> handler p >>= mkCallReply c s
    , dispatchIf = checkCall cond
    }
  where
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
           => CallHandler s a b
           -> Dispatcher s
handleCall = handleCallIf $ state (const True)

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessReply b s))@,
-- the expression @handleCall f@ will yield a "Dispatcher" for inclusion
-- in a 'Behaviour' specification for the /GenProcess/. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@.
--
handleCallIf :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> CallHandler s a b
        -- ^ a reply yielding function over the process state and input message
    -> Dispatcher s
handleCallIf cond handler
  = DispatchIf
    { dispatch   = \s (CallMessage p c) -> handler s p >>= mkReply c
    , dispatchIf = checkCall cond
    }

-- | A variant of 'handleCallFrom_' that ignores the state argument.
--
handleCallFrom_ :: forall s a b . (Serializable a, Serializable b)
                => StatelessCallHandler s a b
                -> Dispatcher s
handleCallFrom_ = handleCallFromIf_ $ input (const True)

-- | A variant of 'handleCallFromIf' that ignores the state argument.
--
handleCallFromIf_ :: forall s a b . (Serializable a, Serializable b)
                  => Condition s a
                  -> StatelessCallHandler s a b
                  -> Dispatcher s
handleCallFromIf_ cond handler =
  DispatchIf {
      dispatch   = \_ (CallMessage p c) -> handler c p >>= mkReply c
    , dispatchIf = checkCall cond
    }

-- | As 'handleCall' but passes the 'CallRef' to the handler function.
-- This can be useful if you wish to /reply later/ to the caller by, e.g.,
-- spawning a process to do some work and have it @replyTo caller response@
-- out of band. In this case the callback can pass the 'CallRef' to the
-- worker (or stash it away itself) and return 'noReply'.
--
handleCallFrom :: forall s a b . (Serializable a, Serializable b)
           => DeferredCallHandler s a b
           -> Dispatcher s
handleCallFrom = handleCallFromIf $ state (const True)

-- | As 'handleCallFrom' but only runs the handler if the supplied 'Condition'
-- evaluates to @True@.
--
handleCallFromIf :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> DeferredCallHandler s a b
        -- ^ a reply yielding function over the process state, sender and input message
    -> Dispatcher s
handleCallFromIf cond handler
  = DispatchIf {
      dispatch   = \s (CallMessage p c) -> handler c s p >>= mkReply c
    , dispatchIf = checkCall cond
    }

-- | Creates a handler for a /typed channel/ RPC style interaction. The
-- handler takes a @SendPort b@ to reply to, the initial input and evaluates
-- to a 'ProcessAction'. It is the handler code's responsibility to send the
-- reply to the @SendPort@.
--
handleRpcChan :: forall s a b . (Serializable a, Serializable b)
              => ChannelHandler s a b
              -> Dispatcher s
handleRpcChan = handleRpcChanIf $ input (const True)

-- | As 'handleRpcChan', but only evaluates the handler if the supplied
-- condition is met.
--
handleRpcChanIf :: forall s a b . (Serializable a, Serializable b)
                => Condition s a
                -> ChannelHandler s a b
                -> Dispatcher s
handleRpcChanIf cond handler
  = DispatchIf {
      dispatch   = \s (ChanMessage p c) -> handler c s p
    , dispatchIf = checkRpc cond
    }

-- | A variant of 'handleRpcChan' that ignores the state argument.
--
handleRpcChan_ :: forall s a b . (Serializable a, Serializable b)
                  => StatelessChannelHandler s a b
                     -- (SendPort b -> a -> (s -> Action s))
                  -> Dispatcher s
handleRpcChan_ = handleRpcChanIf_ $ input (const True)

-- | A variant of 'handleRpcChanIf' that ignores the state argument.
--
handleRpcChanIf_ :: forall s a b . (Serializable a, Serializable b)
                 => Condition s a
                 -> StatelessChannelHandler s a b
                 -> Dispatcher s
handleRpcChanIf_ c h
  = DispatchIf { dispatch   = \s ((ChanMessage m p) :: Message a b) -> h p m s
               , dispatchIf = checkRpc c
               }

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad.
-- > handleCast = handleCastIf (const True)
--
handleCast :: (Serializable a)
           => CastHandler s a
           -> Dispatcher s
handleCast = handleCastIf $ input (const True)

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessAction s))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/.
--
handleCastIf :: forall s a . (Serializable a)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> CastHandler s a
       -- ^ an action yielding function over the process state and input message
    -> Dispatcher s
handleCastIf cond h
  = DispatchIf {
      dispatch   = \s ((CastMessage p) :: Message a ()) -> h s p
    , dispatchIf = checkCast cond
    }

-- | Creates a generic input handler for @STM@ actions, from an ordinary
-- function in the 'Process' monad. The @STM a@ action tells the server how
-- to read inputs, which when presented are passed to the handler in the same
-- manner as @handleInfo@ messages would be.
--
-- Note that messages sent to the server's mailbox will never match this
-- handler, only data arriving via the @STM a@ action will.
--
-- Notably, this kind of handler can be used to pass non-serialisable data to
-- a server process. In such situations, the programmer is responsible for
-- managing the underlying @STM@ infrastructure, and the server simply composes
-- the @STM a@ action with the other reads on its mailbox, using the underlying
-- @matchSTM@ API from distributed-process.
--
-- NB: this function cannot be used with a prioristised process definition.
--
handleExternal :: forall s a . (Serializable a)
               => STM a
               -> ActionHandler s a
               -> ExternDispatcher s
handleExternal a h =
  let matchMsg'   = matchSTM a (\(m :: r) -> return $ unsafeWrapMessage m)
      matchAny' f = matchSTM a (\(m :: r) -> return $ f (unsafeWrapMessage m)) in
  DispatchSTM
    { stmAction   = a
    , dispatchStm = h
    , matchStm    = matchMsg'
    , matchAnyStm = matchAny'
    }

-- | Version of @handleExternal@ that ignores state.
handleExternal_ :: forall s a . (Serializable a)
                => STM a
                -> StatelessHandler s a
                -> ExternDispatcher s
handleExternal_ a h = handleExternal a (flip h)

-- | Handle @call@ style API interactions using arbitrary /STM/ actions.
--
-- The usual @CallHandler@ is preceded by an stm action that, when evaluated,
-- yields a value, and a second expression that is used to send a reply back
-- to the /caller/. The corrolary client API is /callSTM/.
--
handleCallExternal :: forall s r w . (Serializable r)
                   => STM r
                   -> (w -> STM ())
                   -> CallHandler s r w
                   -> ExternDispatcher s
handleCallExternal reader writer handler =
  let matchMsg'   = matchSTM reader (\(m :: r) -> return $ unsafeWrapMessage m)
      matchAny' f = matchSTM reader (\(m :: r) -> return $ f $ unsafeWrapMessage m) in
  DispatchSTM
    { stmAction   = reader
    , dispatchStm = doStmReply handler
    , matchStm    = matchMsg'
    , matchAnyStm = matchAny'
    }
  where
    doStmReply d s m = d s m >>= doXfmReply writer

    doXfmReply _ (NoReply a)         = return a
    doXfmReply _ (ProcessReject _ a) = return a
    doXfmReply w (ProcessReply r' a) = liftIO (atomically $ w r') >> return a

-- | Constructs a /control channel/ handler from a function in the
-- 'Process' monad. The handler expression returns no reply, and the
-- /control message/ is treated in the same fashion as a 'cast'.
--
-- > handleControlChan = handleControlChanIf $ input (const True)
--
handleControlChan :: forall s a . (Serializable a)
    => ControlChannel a -- ^ the receiving end of the control channel
    -> ActionHandler s a
       -- ^ an action yielding function over the process state and input message
    -> ExternDispatcher s
handleControlChan chan h
  = DispatchCC { channel      = snd $ unControl chan
               , dispatchChan = \s ((CastMessage p) :: Message a ()) -> h s p
               }

-- | Version of 'handleControlChan' that ignores the server state.
--
handleControlChan_ :: forall s a. (Serializable a)
           => ControlChannel a
           -> StatelessHandler s a
           -> ExternDispatcher s
handleControlChan_ chan h
  = DispatchCC { channel      = snd $ unControl chan
               , dispatchChan = \s ((CastMessage p) :: Message a ()) -> h p s
               }

-- | Version of 'handleCast' that ignores the server state.
--
handleCast_ :: (Serializable a)
            => StatelessHandler s a
            -> Dispatcher s
handleCast_ = handleCastIf_ $ input (const True)

-- | Version of 'handleCastIf' that ignores the server state.
--
handleCastIf_ :: forall s a . (Serializable a)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> StatelessHandler s a
        -- ^ a function from the input message to a /stateless action/, cf 'continue_'
    -> Dispatcher s
handleCastIf_ cond h
  = DispatchIf { dispatch   = \s ((CastMessage p) :: Message a ()) -> h p $ s
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
    => StatelessHandler s a
          -- ^ a function from the input message to a /stateless action/, cf 'continue_'
    -> Dispatcher s
action h = handleDispatch perform
  where perform :: ActionHandler s a
        perform s a = let f = h a in f s

-- | Constructs a handler for both /call/ and /cast/ messages.
-- @handleDispatch = handleDispatchIf (const True)@
--
handleDispatch :: forall s a . (Serializable a)
               => ActionHandler s a
               -> Dispatcher s
handleDispatch = handleDispatchIf $ input (const True)

-- | Constructs a handler for both /call/ and /cast/ messages. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@.
-- Handlers defined in this way have no access to the call context (if one
-- exists) and cannot therefore reply to calls.
--
handleDispatchIf :: forall s a . (Serializable a)
                 => Condition s a
                 -> ActionHandler s a
                 -> Dispatcher s
handleDispatchIf cond handler = DispatchIf {
      dispatch = doHandle handler
    , dispatchIf = check cond
    }
  where doHandle :: (Serializable a)
                 => ActionHandler s a
                 -> s
                 -> Message a ()
                 -> Process (ProcessAction s)
        doHandle h s msg =
            case msg of
                (CallMessage p _) -> h s p
                (CastMessage p)   -> h s p
                (ChanMessage p _) -> h s p

-- | Creates a generic input handler (i.e., for received messages that are /not/
-- sent using the 'cast' or 'call' APIs) from an ordinary function in the
-- 'Process' monad.
handleInfo :: forall s a. (Serializable a)
           => ActionHandler s a
           -> DeferredDispatcher s
handleInfo h = DeferredDispatcher { dispatchInfo = doHandleInfo h }
  where
    doHandleInfo :: forall s2 a2. (Serializable a2)
                             => ActionHandler s2 a2
                             -> s2
                             -> P.Message
                             -> Process (Maybe (ProcessAction s2))
    doHandleInfo h' s msg = handleMessage msg (h' s)

-- | Handle completely /raw/ input messages.
--
handleRaw :: forall s. ActionHandler s P.Message
          -> DeferredDispatcher s
handleRaw h = DeferredDispatcher { dispatchInfo = doHandle h }
  where
    doHandle h' s msg = fmap Just (h' s msg)

-- | Creates an /exit handler/ scoped to the execution of any and all the
-- registered call, cast and info handlers for the process.
handleExit :: forall s a. (Serializable a)
           => (ProcessId -> ActionHandler s a)
           -> ExitSignalDispatcher s
handleExit h = ExitSignalDispatcher { dispatchExit = doHandleExit h }
  where
    doHandleExit :: (ProcessId -> ActionHandler s a)
                 -> s
                 -> ProcessId
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
    doHandleExit h' s p msg = handleMessage msg (h' p s)

-- | Conditional version of @handleExit@
handleExitIf :: forall s a . (Serializable a)
             => (s -> a -> Bool)
             -> (ProcessId -> ActionHandler s a)
             -> ExitSignalDispatcher s
handleExitIf c h = ExitSignalDispatcher { dispatchExit = doHandleExit c h }
  where
    doHandleExit :: (s -> a -> Bool)
                 -> (ProcessId -> ActionHandler s a)
                 -> s
                 -> ProcessId
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
    doHandleExit c' h' s p msg = handleMessageIf msg (c' s) (h' p s)

-- handling 'reply-to' in the main process loop is awkward at best,
-- so we handle it here instead and return the 'action' to the loop
mkReply :: (Serializable b)
        => CallRef b
        -> ProcessReply b s
        -> Process (ProcessAction s)
mkReply cRef act
  | (NoReply a)          <- act  = return a
  | (CallRef (_, tg'))   <- cRef
  , (ProcessReply  r' a) <- act  = sendTo cRef (CallResponse r' tg') >> return a
  | (CallRef (_, ct'))   <- cRef
  , (ProcessReject r' a) <- act  = sendTo cRef (CallRejected r' ct') >> return a
  | otherwise                    = die $ ExitOther "mkReply.InvalidState"

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
