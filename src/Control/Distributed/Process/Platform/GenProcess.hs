{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.GenProcess
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a high(er) level API for building complex 'Process'
-- implementations by abstracting out the management of the process' mailbox,
-- reply/response handling, timeouts, process hiberation, error handling
-- and shutdown/stop procedures. It is modelled along similar lines to OTP's
-- gen_server API - <http://www.erlang.org/doc/man/gen_server.html>.
--
-- [API Overview]
--
-- Once started, a generic process will consume messages from its mailbox and
-- pass them on to user defined /handlers/ based on the types received (mapped
-- to those accepted by the handlers) and optionally by also evaluating user
-- supplied predicates to determine which handlers are valid.
-- Each handler returns a 'ProcessAction' which specifies how we should proceed.
-- If none of the handlers is able to process a message (because their types are
-- incompatible) then the process 'unhandledMessagePolicy' will be applied.
--
-- The 'ProcessAction' type defines the ways in which a process can respond
-- to its inputs, either by continuing to read incoming messages, setting an
-- optional timeout, sleeping for a while or by stopping. The optional timeout
-- behaves a little differently to the other process actions. If no messages
-- are received within the specified time span, the process 'timeoutHandler'
-- will be called in order to determine the next action.
--
-- Generic processes are defined by the 'ProcessDefinition' type, using record
-- syntax. The 'ProcessDefinition' fields contain handlers (or lists of them)
-- for specific tasks. In addtion to the @timeoutHandler@, a 'ProcessDefinition'
-- may also define a @terminateHandler@ which is called just before the process
-- exits. This handler will be called /whenever/ the process is stopping, i.e.,
-- when a callback returns 'stop' as the next action /or/ if an unhandled exit
-- signal or similar asynchronous exception is thrown in (or to) the process
-- itself.
--
-- The other handlers are split into two groups: /apiHandlers/ and /infoHandlers/.
-- The former contains handlers for the 'cast' and 'call' protocols, whilst the
-- latter contains handlers that deal with input messages which are not sent
-- via these API calls (i.e., messages sent using bare 'send' or signals put
-- into the process mailbox by the node controller, such as
-- 'ProcessMonitorNotification' and the like).
--
-- [The Cast/Call Protocol]
--
-- Deliberate interactions with the process will usually fall into one of two
-- categories. A 'cast' interaction involves a client sending a message
-- asynchronously and the server handling this input. No reply is sent to
-- the client. On the other hand, a 'call' interaction is a kind of /rpc/
-- where the client sends a message and waits for a reply.
--
-- The expressions given to @apiHandlers@ have to conform to the /cast|call/
-- protocol. The details of this are, however, hidden from the user. A set
-- of API functions for creating @apiHandlers@ are given instead, which
-- take expressions (i.e., a function or lambda expression) and create the
-- appropriate @Dispatcher@ for handling the cast (or call).
--
-- The cast/call protocol handlers deal with /expected/ inputs. These form
-- the explicit public API for the process, and will usually be exposed by
-- providing module level functions that defer to the cast/call API. For
-- example:
--
-- @
-- add :: ProcessId -> Double -> Double -> Double
-- add pid x y = call pid (Add x y)
-- @
--
-- [Handling Info Messages]
--
-- An explicit protocol for communicating with the process can be
-- configured using 'cast' and 'call', but it is not possible to prevent
-- other kinds of messages from being sent to the process mailbox. When
-- any message arrives for which there are no handlers able to process
-- its content, the 'UnhandledMessagePolicy' will be applied. Sometimes
-- it is desireable to process incoming messages which aren't part of the
-- protocol, rather than let the policy deal with them. This is particularly
-- true when incoming messages are important to the process, but their point
-- of origin is outside the developer's control. Handling /signals/ such as
-- 'ProcessMonitorNotification' is a typical example of this:
--
-- > handleInfo_ (\(ProcessMonitorNotification _ _ r) -> say $ show r >> continue_)
--
-- [Handling Process State]
--
-- The 'ProcessDefinition' is parameterised by the type of state it maintains.
-- A process that has no state will have the type @ProcessDefinition ()@ and can
-- be bootstrapped by evaluating 'statelessProcess'.
--
-- All call/cast handlers come in two flavours, those which take the process
-- state as an input and those which do not. Handlers that ignore the process
-- state have to return a function that takes the state and returns the required
-- action. Versions of the various action generating functions ending in an
-- underscore are provided to simplify this:
--
-- @
--   statelessProcess {
--       apiHandlers = [
--         handleCall_   (\\(n :: Int) -> return (n * 2))
--       , handleCastIf_ (\\(c :: String, _ :: Delay) -> c == \"timeout\")
--                       (\\(\"timeout\", Delay d) -> timeoutAfter_ d)
--       ]
--     , timeoutHandler = \\_ _ -> stop $ TerminateOther \"timeout\"
--   }
-- @
--
-- [Handling Errors]
--
-- Error handling appears in several contexts and process definitions can
-- hook into these with relative ease. Only process failures as a result of
-- asynchronous exceptions are supported by the API, which provides several
-- scopes for error handling.
--
-- Catching exceptions inside handler functions is no different to ordinary
-- exception handling in monadic code.
--
-- @
--   handleCall (\\x y ->
--                catch (hereBeDragons x y)
--                      (\\(e :: SmaugTheTerribleException) ->
--                           return (Left (show e))))
-- @
--
-- The caveats mentioned in "Control.Distributed.Process.Platform" about
-- exit signal handling obviously apply here as well.
--
-- [Structured Exit Signal Handling]
--
-- Because "Control.Distributed.Process.ProcessExitException" is a ubiquitous
-- /signalling mechanism/ in Cloud Haskell, it is treated unlike other
-- asynchronous exceptions. The 'ProcessDefinition' 'exitHandlers' field
-- accepts a list of handlers that, for a specific exit reason, can decide
-- how the process should respond. If none of these handlers matches the
-- type of @reason@ then the process will exit with @DiedException why@. In
-- addition, a default /exit handler/ is installed for exit signals where the
-- @reason == Shutdown@, because this is an /exit signal/ used explicitly and
-- extensively throughout the platform. The default behaviour is to gracefully
-- shut down the process, calling the @terminateHandler@ as usual, before
-- stopping with @TerminateShutdown@ given as the final outcome.
--
-- /Example: How to annoy your supervisor and end up force-killed:/
--
-- > handleExit  (\state from (sigExit :: Shutdown) -> continue s)
--
-- That code is, of course, very silly. Under some circumstances, handling
-- exit signals is perfectly legitimate. Handling of /other/ forms of
-- asynchronous exception is not supported by this API.
--
-- If any asynchronous exception goes unhandled, the process will immediately
-- exit without running the @terminateHandler@. It is very important to note
-- that in Cloud Haskell, link failures generate asynchronous exceptions in
-- the target and these will NOT be caught by the API and will therefore
-- cause the process to exit /without running the termination handler/
-- callback. If your termination handler is set up to do important work
-- (such as resource cleanup) then you should avoid linking you process
-- and use monitors instead.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.GenProcess
  ( -- * Exported data types
    InitResult(..)
  , ProcessAction(..)
  , ProcessReply
  , CallHandler
  , CastHandler
  , InitHandler
  , TerminateHandler
  , TimeoutHandler
  , UnhandledMessagePolicy(..)
  , ProcessDefinition(..)
    -- * Client interaction with the process
  , start
  , runProcess
  , shutdown
  , defaultProcess
  , statelessProcess
  , statelessInit
  , call
  , safeCall
  , tryCall
  , callAsync
  , callTimeout
  , cast
    -- * Handler interaction inside the process
  , condition
  , state
  , input
  , reply
  , replyWith
  , noReply
  , noReply_
  , haltNoReply_
  , continue
  , continue_
  , timeoutAfter
  , timeoutAfter_
  , hibernate
  , hibernate_
  , stop
  , stop_
  , replyTo
    -- * Handler callback creation
  , handleCall
  , handleCallIf
  , handleCallFrom
  , handleCallFromIf
  , handleCast
  , handleCastIf
  , handleInfo
  , handleDispatch
  , handleExit
    -- * Stateless handlers
  , action
  , handleCall_
  , handleCallIf_
  , handleCast_
  , handleCastIf_
  ) where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Async hiding (check)
import Control.Distributed.Process.Platform.Internal.Primitives
import Control.Distributed.Process.Platform.Internal.Types
  ( Recipient(..)
  , TerminateReason(..)
  , Shutdown(..)
  )
import Control.Distributed.Process.Platform.Internal.Common
import Control.Distributed.Process.Platform.Time

import Data.Binary hiding (decode)
import Data.DeriveTH
import Data.Typeable (Typeable)
import Prelude hiding (init)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

data Message a =
    CastMessage a
  | CallMessage a Recipient
  deriving (Typeable)
$(derive makeBinary ''Message)

data CallResponse a = CallResponse a
  deriving (Typeable)
$(derive makeBinary ''CallResponse)

-- | Return type for and 'InitHandler' expression.
data InitResult s =
    InitOk s Delay {-
        ^ denotes successful initialisation, initial state and timeout -}
  | forall r. (Serializable r)
    => InitFail r -- ^ denotes failed initialisation and the reason

-- | The action taken by a process after a handler has run and its updated state.
-- See 'continue'
--     'timeoutAfter'
--     'hibernate'
--     'stop'
--
data ProcessAction s =
    ProcessContinue  s                -- ^ continue with (possibly new) state
  | ProcessTimeout   TimeInterval s   -- ^ timeout if no messages are received
  | ProcessHibernate TimeInterval s   -- ^ hibernate for /delay/
  | ProcessStop      TerminateReason  -- ^ stop the process, giving @TerminateReason@

-- | Returned from handlers for the synchronous 'call' protocol, encapsulates
-- the reply data /and/ the action to take after sending the reply. A handler
-- can return @NoReply@ if they wish to ignore the call.
data ProcessReply s a =
    ProcessReply a (ProcessAction s)
  | NoReply (ProcessAction s)

type CallHandler a s = s -> a -> Process (ProcessReply s a)

type CastHandler s = s -> Process ()

-- type InfoHandler a = forall a b. (Serializable a, Serializable b) => a -> Process b

-- | Wraps a predicate that is used to determine whether or not a handler
-- is valid based on some combination of the current process state, the
-- type and/or value of the input message or both.
data Condition s m =
    Condition (s -> m -> Bool)  -- ^ predicated on the process state /and/ the message
  | State     (s -> Bool) -- ^ predicated on the process state only
  | Input     (m -> Bool) -- ^ predicated on the input message only

-- | An expression used to initialise a process with its state.
type InitHandler a s = a -> Process (InitResult s)

-- | An expression used to handle process termination.
type TerminateHandler s = s -> TerminateReason -> Process ()

-- | An expression used to handle process timeouts.
type TimeoutHandler s = s -> Delay -> Process (ProcessAction s)

-- dispatching to implementation callbacks

-- | Provides dispatch from cast and call messages to a typed handler.
data Dispatcher s =
    forall a . (Serializable a) => Dispatch {
        dispatch :: s -> Message a -> Process (ProcessAction s)
      }
  | forall a . (Serializable a) => DispatchIf {
        dispatch   :: s -> Message a -> Process (ProcessAction s)
      , dispatchIf :: s -> Message a -> Bool
      }

-- | Provides dispatch for any input, returns 'Nothing' for unhandled messages.
data DeferredDispatcher s = DeferredDispatcher {
    dispatchInfo :: s
                 -> AbstractMessage
                 -> Process (Maybe (ProcessAction s))
  }

-- | Provides dispatch for any exit signal - returns 'Nothing' for unhandled exceptions
data ExitSignalDispatcher s = ExitSignalDispatcher {
    dispatchExit :: s
                 -> ProcessId
                 -> AbstractMessage
                 -> Process (Maybe (ProcessAction s))
  }

class MessageMatcher d where
    matchMessage :: UnhandledMessagePolicy -> s -> d s -> Match (ProcessAction s)

instance MessageMatcher Dispatcher where
  matchMessage _ s (Dispatch   d)      = match (d s)
  matchMessage _ s (DispatchIf d cond) = matchIf (cond s) (d s)

-- | Policy for handling unexpected messages, i.e., messages which are not
-- sent using the 'call' or 'cast' APIs, and which are not handled by any of the
-- 'handleInfo' handlers.
data UnhandledMessagePolicy =
    Terminate  -- ^ stop immediately, giving @TerminateOther "UnhandledInput"@ as the reason
  | DeadLetter ProcessId -- ^ forward the message to the given recipient
  | Drop                 -- ^ dequeue and then drop/ignore the message

-- | Stores the functions that determine runtime behaviour in response to
-- incoming messages and a policy for responding to unhandled messages.
data ProcessDefinition s = ProcessDefinition {
    apiHandlers  :: [Dispatcher s]     -- ^ functions that handle call/cast messages
  , infoHandlers :: [DeferredDispatcher s] -- ^ functions that handle non call/cast messages
  , exitHandlers :: [ExitSignalDispatcher s] -- ^ functions that handle exit signals
  , timeoutHandler :: TimeoutHandler s   -- ^ a function that handles timeouts
  , terminateHandler :: TerminateHandler s -- ^ a function that is run just before the process exits
  , unhandledMessagePolicy :: UnhandledMessagePolicy -- ^ how to deal with unhandled messages
  }

--------------------------------------------------------------------------------
-- Client API                                                                 --
--------------------------------------------------------------------------------

-- TODO: automatic registration

-- | Starts a gen-process configured with the supplied process definition,
-- using an init handler and its initial arguments. This code will run the
-- 'Process' until completion and return @Right TerminateReason@ *or*,
-- if initialisation fails, return @Left InitResult@ which will be
-- @InitFail why@.
start :: a
      -> InitHandler a s
      -> ProcessDefinition s
      -> Process (Either (InitResult s) TerminateReason)
start = runProcess recvLoop

runProcess :: (ProcessDefinition s -> s -> Delay -> Process TerminateReason)
           -> a
           -> InitHandler a s
           -> ProcessDefinition s
           -> Process (Either (InitResult s) TerminateReason)
runProcess loop args init def = do
  ir <- init args
  case ir of
    InitOk s d -> loop def s d >>= return . Right
    f@(InitFail _) -> return $ Left f

-- | Send a signal instructing the process to terminate. The /receive loop/ which
-- manages the process mailbox will prioritise @Shutdown@ signals higher than
-- any other incoming messages, but the server might be busy (i.e., still in the
-- process of excuting a handler) at the time of sending however, so the caller
-- should not make any assumptions about the timeliness with which the shutdown
-- signal will be handled. If responsiveness is important, a better approach
-- might be to send an /exit signal/ with 'Shutdown' as the reason. An exit
-- signal will interrupt any operation currently underway and force the running
-- process to clean up and terminate.
shutdown :: ProcessId -> Process ()
shutdown pid = cast pid Shutdown

defaultProcess :: ProcessDefinition s
defaultProcess = ProcessDefinition {
    apiHandlers      = []
  , infoHandlers     = []
  , exitHandlers     = []
  , timeoutHandler   = \s _ -> continue s
  , terminateHandler = \_ _ -> return ()
  , unhandledMessagePolicy = Terminate
  } :: ProcessDefinition s

-- | A basic, stateless process definition, where the unhandled message policy
-- is set to 'Terminate', the default timeout handlers does nothing (i.e., the
-- same as calling @continue ()@ and the terminate handler is a no-op.
statelessProcess :: ProcessDefinition ()
statelessProcess = ProcessDefinition {
    apiHandlers            = []
  , infoHandlers           = []
  , exitHandlers           = []
  , timeoutHandler         = \s _ -> continue s
  , terminateHandler       = \_ _ -> return ()
  , unhandledMessagePolicy = Terminate
  }

-- | A basic, state /unaware/ 'InitHandler' that can be used with
-- 'statelessProcess'.
statelessInit :: Delay -> InitHandler () ()
statelessInit d () = return $ InitOk () d

-- | Make a synchronous call - will block until a reply is received.
-- The calling process will exit with 'TerminateReason' if the calls fails.
call :: forall a b . (Serializable a, Serializable b)
                 => ProcessId -> a -> Process b
call sid msg = callAsync sid msg >>= wait >>= unpack -- note [call using async]
  where unpack :: AsyncResult b -> Process b
        unpack (AsyncDone   r)     = return r
        unpack (AsyncFailed r)     = die $ explain "CallFailed" r
        unpack (AsyncLinkFailed r) = die $ explain "LinkFailed" r
        unpack AsyncCancelled      = die $ TerminateOther $ "Cancelled"
        unpack AsyncPending        = terminate -- as this *cannot* happen

-- | Safe version of 'call' that returns information about the error
-- if the operation fails. If an error occurs then the explanation will be
-- will be stashed away as @(TerminateOther String)@.
safeCall :: forall a b . (Serializable a, Serializable b)
                 => ProcessId -> a -> Process (Either TerminateReason b)
safeCall s m = callAsync s m >>= wait >>= unpack    -- note [call using async]
  where unpack (AsyncDone   r)     = return $ Right r
        unpack (AsyncFailed r)     = return $ Left $ explain "CallFailed" r
        unpack (AsyncLinkFailed r) = return $ Left $ explain "LinkFailed" r
        unpack AsyncCancelled      = return $ Left $ TerminateOther $ "Cancelled"
        unpack AsyncPending        = return $ Left $ TerminateOther $ "Pending"

-- | Version of 'safeCall' that returns 'Nothing' if the operation fails. If
-- you need information about *why* a call has failed then you should use
-- 'safeCall' or combine @catchExit@ and @call@ instead.
tryCall :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> Process (Maybe b)
tryCall s m = callAsync s m >>= wait >>= unpack    -- note [call using async]
  where unpack (AsyncDone r) = return $ Just r
        unpack _             = return Nothing

-- | Make a synchronous call, but timeout and return @Nothing@ if the reply
-- is not received within the specified time interval.
--
-- If the result of the call is a failure (or the call was cancelled) then
-- the calling process will exit, with the 'AsyncResult' given as the reason.
--
callTimeout :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> TimeInterval -> Process (Maybe b)
callTimeout s m d = callAsync s m >>= waitTimeout d >>= unpack
  where unpack :: (Serializable b) => Maybe (AsyncResult b) -> Process (Maybe b)
        unpack Nothing              = return Nothing
        unpack (Just (AsyncDone r)) = return $ Just r
        unpack (Just other)         = die other

-- | Performs a synchronous 'call' to the the given server address, however the
-- call is made /out of band/ and an async handle is returned immediately. This
-- can be passed to functions in the /Async/ API in order to obtain the result.
--
-- See "Control.Distributed.Process.Platform.Async"
--
callAsync :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> Process (Async b)
callAsync = callAsyncUsing async

-- | As 'callAsync' but takes a function that can be used to generate an async
-- task and return an async handle to it. This can be used to switch between
-- async implementations, by e.g., using an async channel instead of the default
-- STM based handle.
--
-- See "Control.Distributed.Process.Platform.Async"
--
callAsyncUsing :: forall s a b . (Addressable s, Serializable a, Serializable b)
                  => (Process b -> Process (Async b))
                  -> s -> a -> Process (Async b)
callAsyncUsing asyncStart sid msg = do
  asyncStart $ do  -- note [call using async]
    (Just pid) <- resolve sid
    mRef <- monitor pid
    wpid <- getSelfPid
    sendTo sid (CallMessage msg (Pid wpid))
    r <- receiveWait [
            match (\((CallResponse m) :: CallResponse b) -> return (Right m))
          , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
              (\(ProcessMonitorNotification _ _ reason) -> return (Left reason))
        ]
    -- TODO: better failure API
    unmonitor mRef
    case r of
      Right m  -> return m
      Left err -> die $ TerminateOther ("ServerExit (" ++ (show err) ++ ")")

-- note [call using async]
-- One problem with using plain expect/receive primitives to perform a
-- synchronous (round trip) call is that a reply matching the expected type
-- could come from anywhere! The Call.hs module uses a unique integer tag to
-- distinguish between inputs but this is easy to forge, as is tagging the
-- response with the sender's pid.
--
-- The approach we take here is to rely on AsyncSTM (by default) to insulate us
-- from erroneous incoming messages without the need for tagging. The /handle/
-- returned uses an @STM (AsyncResult a)@ field to handle the response /and/
-- the implementation spawns a new process to perform the actual call and
-- await the reply before atomically updating the result. Whilst in theory,
-- given a hypothetical 'listAllProcesses' primitive, it might be possible for
-- malacious code to obtain the ProcessId of the worker and send a false reply,
-- the likelihood of this is small enough that it seems reasonable to assume
-- we've solved the problem without the need for tags or globally unique
-- identifiers.

-- | Sends a /cast/ message to the server identified by 'ServerId'. The server
-- will not send a response. Like Cloud Haskell's 'send' primitive, cast is
-- fully asynchronous and /never fails/ - therefore 'cast'ing to a non-existent
-- (e.g., dead) server process will not generate an error.
cast :: forall a m . (Addressable a, Serializable m)
                 => a -> m -> Process ()
cast sid msg = sendTo sid (CastMessage msg)

--------------------------------------------------------------------------------
-- Producing ProcessAction and ProcessReply from inside handler expressions   --
--------------------------------------------------------------------------------

-- | Creates a 'Conditon' from a function that takes a process state @a@ and
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
reply :: (Serializable r) => r -> s -> Process (ProcessReply s r)
reply r s = continue s >>= replyWith r

-- | Instructs the process to send a reply /and/ evaluate the 'ProcessAction'.
replyWith :: (Serializable m)
          => m
          -> ProcessAction s
          -> Process (ProcessReply s m)
replyWith msg st = return $ ProcessReply msg st

-- | Instructs the process to skip sending a reply /and/ evaluate a 'ProcessAction'
noReply :: (Serializable r) => ProcessAction s -> Process (ProcessReply s r)
noReply = return . NoReply

-- | Continue without giving a reply to the caller - equivalent to 'continue',
-- but usable in a callback passed to the 'handleCall' family of functions.
noReply_ :: forall s r . (Serializable r) => s -> Process (ProcessReply s r)
noReply_ s = continue s >>= noReply

-- | Halt process execution during a call handler, without paying any attention
-- to the expected return type.
haltNoReply_ :: TerminateReason -> Process (ProcessReply s TerminateReason)
haltNoReply_ r = stop r >>= noReply

-- | Instructs the process to continue running and receiving messages.
continue :: s -> Process (ProcessAction s)
continue = return . ProcessContinue

-- | Version of 'continue' that can be used in handlers that ignore process state.
--
continue_ :: (s -> Process (ProcessAction s))
continue_ = return . ProcessContinue

-- | Instructs the process to wait for incoming messages until 'TimeInterval'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @TimeInterval@ will remain in use until changed.
timeoutAfter :: TimeInterval -> s -> Process (ProcessAction s)
timeoutAfter d s = return $ ProcessTimeout d s

-- | Version of 'timeoutAfter' that can be used in handlers that ignore process state.
--
-- > action (\(TimeoutPlease duration) -> timeoutAfter_ duration)
--
timeoutAfter_ :: TimeInterval -> (s -> Process (ProcessAction s))
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
-- 'terminateHandler' is installed, it will be called with the 'TerminateReason'
-- returned from this call, along with the process state.
stop :: TerminateReason -> Process (ProcessAction s)
stop r = return $ ProcessStop r

-- | Version of 'stop' that can be used in handlers that ignore process state.
--
-- > action (\ClientError -> stop_ TerminateNormal)
--
stop_ :: TerminateReason -> (s -> Process (ProcessAction s))
stop_ r _ = stop r

replyTo :: (Serializable m) => Recipient -> m -> Process ()
replyTo client msg = sendTo client (CallResponse msg)

--------------------------------------------------------------------------------
-- Wrapping handler expressions in Dispatcher and DeferredDispatcher          --
--------------------------------------------------------------------------------

-- | Constructs a 'call' handler from a function in the 'Process' monad.
-- The handler expression returns the reply, and the action will be
-- set to 'continue'.
--
-- > handleCall_ = handleCallIf_ (const True)
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
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h p) >>= mkCallReply c s
        doHandle _ _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- cannot happen!

        -- handling 'reply-to' in the main process loop is awkward at best,
        -- so we handle it here instead and return the 'action' to the loop
        mkCallReply :: (Serializable b)
                => Recipient -> s -> b -> Process (ProcessAction s)
        mkCallReply c s m = sendTo c (CallResponse m) >> continue s

-- | Constructs a 'call' handler from a function in the 'Process' monad.
-- > handleCall = handleCallIf (const True)
--
handleCall :: (Serializable a, Serializable b)
           => (s -> a -> Process (ProcessReply s b))
           -> Dispatcher s
handleCall = handleCallIf $ state (const True)

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessReply s b))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@
--
handleCallIf :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (s -> a -> Process (ProcessReply s b))
        -- ^ a reply yielding function over the process state and input message
    -> Dispatcher s
handleCallIf cond handler
  = DispatchIf {
      dispatch   = doHandle handler
    , dispatchIf = checkCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> a -> Process (ProcessReply s b))
                 -> s
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s p) >>= mkReply c
        doHandle _ _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- cannot happen!

-- | As 'handleCall' but passes the 'Recipient' to the handler function.
-- This can be useful if you wish to /reply later/ to the caller by, e.g.,
-- spawning a process to do some work and have it @replyTo caller response@
-- out of band. In this case the callback can pass the 'Recipient' to the
-- worker (or stash it away itself) and return 'noReply'.
--
handleCallFrom :: forall s a b . (Serializable a, Serializable b)
           => (s -> Recipient -> a -> Process (ProcessReply s b))
           -> Dispatcher s
handleCallFrom = handleCallFromIf $ state (const True)

-- | As 'handleCallFrom' but only runs the handler if the supplied 'Condition'
-- evaluates to @True@.
--
handleCallFromIf :: forall s a b . (Serializable a, Serializable b)
    => Condition s a -- ^ predicate that must be satisfied for the handler to run
    -> (s -> Recipient -> a -> Process (ProcessReply s b))
        -- ^ a reply yielding function over the process state, sender and input message
    -> Dispatcher s
handleCallFromIf cond handler
  = DispatchIf {
      dispatch   = doHandle handler
    , dispatchIf = checkCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> Recipient -> a -> Process (ProcessReply s b))
                 -> s
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s c p) >>= mkReply c
        doHandle _ _ _ = die "CALL_HANDLER_TYPE_MISMATCH" -- cannot happen!

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
      dispatch   = (\s (CastMessage p) -> h s p)
    , dispatchIf = checkCast cond
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
  = DispatchIf {
      dispatch   = (\s (CastMessage p) -> h p $ s)
    , dispatchIf = checkCast cond
    }

-- | Constructs an /action/ handler. Like 'handleDispatch' this can handle both
-- 'cast' and 'call' messages and you won't know which you're dealing with.
-- This can be useful where certain inputs require a definite action, such as
-- stopping the server, without concern for the state (e.g., when stopping we
-- need only decide to stop, as the terminate handler can deal with state
-- cleanup etc). For example:
--
-- @action (\MyCriticalErrorSignal -> stop_ TerminateNormal)@
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
handleDispatch :: (Serializable a)
               => (s -> a -> Process (ProcessAction s))
               -> Dispatcher s
handleDispatch = handleDispatchIf $ input (const True)

-- | Constructs a handler for both /call/ and /cast/ messages. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@.
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
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s msg =
            case msg of
                (CallMessage p _) -> (h s p)
                (CastMessage p)   -> (h s p)

-- | Creates a generic input handler (i.e., for recieved messages that are /not/
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
                             -> AbstractMessage
                             -> Process (Maybe (ProcessAction s2))
    doHandleInfo h' s msg = maybeHandleMessage msg (h' s)

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
                 -> AbstractMessage
                 -> Process (Maybe (ProcessAction s))
    doHandleExit h' s p msg = maybeHandleMessage msg (h' s p)

-- handling 'reply-to' in the main process loop is awkward at best,
-- so we handle it here instead and return the 'action' to the loop
mkReply :: (Serializable b)
           => Recipient -> ProcessReply s b -> Process (ProcessAction s)
mkReply c (ProcessReply r' a) = sendTo c (CallResponse r') >> return a
mkReply _ (NoReply a)         = return a

-- these functions are the inverse of 'condition', 'state' and 'input'

check :: forall s m . (Serializable m)
            => Condition s m
            -> s
            -> Message m
            -> Bool
check (Condition c) st msg = c st $ decode msg
check (State     c) st _   = c st
check (Input     c) _  msg = c $ decode msg

checkCall :: forall s m . (Serializable m)
             => Condition s m
             -> s
             -> Message m
             -> Bool
checkCall cond st msg@(CallMessage _ _) = check cond st msg
checkCall _    _     _                  = False

checkCast :: forall s m . (Serializable m)
             => Condition s m
             -> s
             -> Message m
             -> Bool
checkCast cond st msg@(CastMessage _) = check cond st msg
checkCast _    _     _                = False

decode :: Message a -> a
decode (CallMessage a _) = a
decode (CastMessage a)   = a

--------------------------------------------------------------------------------
-- Internal Process Implementation                                            --
--------------------------------------------------------------------------------

recvLoop :: ProcessDefinition s -> s -> Delay -> Process TerminateReason
recvLoop pDef pState recvDelay =
  let p             = unhandledMessagePolicy pDef
      handleTimeout = timeoutHandler pDef
      handleStop    = terminateHandler pDef
      shutdown'     = matchMessage p pState shutdownHandler
      matchers      = map (matchMessage p pState) (apiHandlers pDef)
      ex'           = (exitHandlers pDef) ++ [trapExit]
      ms' = (shutdown':matchers) ++ matchAux p pState (infoHandlers pDef)
  in do
    ac <- catchesExit (processReceive ms' handleTimeout pState recvDelay)
                      (map (\d' -> (dispatchExit d') pState) ex')
    case ac of
        (ProcessContinue s')     -> recvLoop pDef s' recvDelay
        (ProcessTimeout t' s')   -> recvLoop pDef s' (Delay t')
        (ProcessHibernate d' s') -> block d' >> recvLoop pDef s' recvDelay
        (ProcessStop r) -> handleStop pState r >> return (r :: TerminateReason)

-- an explicit 'cast' giving 'Shutdown' will stop the server gracefully
shutdownHandler :: Dispatcher s
shutdownHandler = handleCast (\_ Shutdown -> stop $ TerminateShutdown)

-- @(ProcessExitException from Shutdown)@ will stop the server gracefully
trapExit :: ExitSignalDispatcher s
trapExit = handleExit (\_ (_ :: ProcessId) Shutdown -> stop $ TerminateShutdown)

block :: TimeInterval -> Process ()
block i = liftIO $ threadDelay (asTimeout i)

applyPolicy :: UnhandledMessagePolicy
            -> s
            -> AbstractMessage
            -> Process (ProcessAction s)
applyPolicy p s m =
  case p of
    Terminate      -> stop $ TerminateOther "UnhandledInput"
    DeadLetter pid -> forward m pid >> continue s
    Drop           -> continue s

matchAux :: UnhandledMessagePolicy
         -> s
         -> [DeferredDispatcher s]
         -> [Match (ProcessAction s)]
matchAux p ps ds = [matchAny (auxHandler (applyPolicy p ps) ps ds)]

auxHandler :: (AbstractMessage -> Process (ProcessAction s))
           -> s
           -> [DeferredDispatcher s]
           -> AbstractMessage
           -> Process (ProcessAction s)
auxHandler policy _  [] msg = policy msg
auxHandler policy st (d:ds :: [DeferredDispatcher s]) msg
  | length ds > 0  = let dh = dispatchInfo d in do
    -- NB: we *do not* want to terminate/dead-letter messages until
    -- we've exhausted all the possible info handlers
      m <- dh st msg
      case m of
        Nothing  -> auxHandler policy st ds msg
        Just act -> return act
      -- but here we *do* let the policy kick in
  | otherwise = let dh = dispatchInfo d in do
      m <- dh st msg
      case m of
        Nothing  -> policy msg
        Just act -> return act

processReceive :: [Match (ProcessAction s)]
               -> TimeoutHandler s
               -> s
               -> Delay
               -> Process (ProcessAction s)
processReceive ms handleTimeout st d = do
    next <- recv ms d
    case next of
        Nothing -> handleTimeout st d
        Just pa -> return pa
  where
    recv :: [Match (ProcessAction s)]
         -> Delay
         -> Process (Maybe (ProcessAction s))
    recv matches d' =
        case d' of
            Infinity -> receiveWait matches >>= return . Just
            Delay t' -> receiveTimeout (asTimeout t') matches

