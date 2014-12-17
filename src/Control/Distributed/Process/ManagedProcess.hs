{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE RecordWildCards            #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.ManagedProcess
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a high(er) level API for building complex @Process@
-- implementations by abstracting out the management of the process' mailbox,
-- reply/response handling, timeouts, process hiberation, error handling
-- and shutdown/stop procedures. It is modelled along similar lines to OTP's
-- gen_server API - <http://www.erlang.org/doc/man/gen_server.html>.
--
-- In particular, a /managed process/ will interoperate cleanly with the
-- "Control.Distributed.Process.Platform.Supervisor" API.
--
-- [API Overview]
--
-- Once started, a /managed process/ will consume messages from its mailbox and
-- pass them on to user defined /handlers/ based on the types received (mapped
-- to those accepted by the handlers) and optionally by also evaluating user
-- supplied predicates to determine which handler(s) should run.
-- Each handler returns a 'ProcessAction' which specifies how we should proceed.
-- If none of the handlers is able to process a message (because their types are
-- incompatible), then the 'unhandledMessagePolicy' will be applied.
--
-- The 'ProcessAction' type defines the ways in which our process can respond
-- to its inputs, whether by continuing to read incoming messages, setting an
-- optional timeout, sleeping for a while or stopping. The optional timeout
-- behaves a little differently to the other process actions. If no messages
-- are received within the specified time span, a user defined 'timeoutHandler'
-- will be called in order to determine the next action.
--
-- The 'ProcessDefinition' type also defines a @shutdownHandler@,
-- which is called whenever the process exits, whether because a callback has
-- returned 'stop' as the next action, or as the result of unhandled exit signal
-- or similar asynchronous exceptions thrown in (or to) the process itself.
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
-- Deliberate interactions with a /managed process/ usually fall into one of
-- two categories. A 'cast' interaction involves a client sending a message
-- asynchronously and the server handling this input. No reply is sent to
-- the client. On the other hand, a 'call' is a /remote procedure call/,
-- where the client sends a message and waits for a reply from the server.
--
-- All expressions given to @apiHandlers@ have to conform to the /cast|call/
-- protocol. The protocol (messaging) implementation is hidden from the user;
-- API functions for creating user defined @apiHandlers@ are given instead,
-- which take expressions (i.e., a function or lambda expression) and create the
-- appropriate @Dispatcher@ for handling the cast (or call).
--
-- These cast/call protocols are for dealing with /expected/ inputs. They
-- will usually form the explicit public API for the process, and be exposed by
-- providing module level functions that defer to the cast/call API, giving
-- the author an opportunity to enforce the correct types. For
-- example:
--
-- @
-- {- Ask the server to add two numbers -}
-- add :: ProcessId -> Double -> Double -> Double
-- add pid x y = call pid (Add x y)
-- @
--
-- Note here that the return type from the call is /inferred/ and will not be
-- enforced by the type system. If the server sent a different type back in
-- the reply, then the caller might be blocked indefinitely! In fact, the
-- result of mis-matching the expected return type (in the client facing API)
-- with the actual type returned by the server is more severe in practise.
-- The underlying types that implement the /call/ protocol carry information
-- about the expected return type. If there is a mismatch between the input and
-- output types that the client API uses and those which the server declares it
-- can handle, then the message will be considered unroutable - no handler will
-- be executed against it and the unhandled message policy will be applied. You
-- should, therefore, take great care to align these types since the default
-- unhandled message policy is to terminate the server! That might seem pretty
-- extreme, but you can alter the unhandled message policy and/or use the
-- various overloaded versions of the call API in order to detect errors on the
-- server such as this.
--
-- The cost of potential type mismatches between the client and server is the
-- main disadvantage of this looser coupling between them. This mechanism does
-- however, allow servers to handle a variety of messages without specifying the
-- entire protocol to be supported in excruciating detail.
--
-- [Handling Unexpected/Info Messages]
--
-- An explicit protocol for communicating with the process can be
-- configured using 'cast' and 'call', but it is not possible to prevent
-- other kinds of messages from being sent to the process mailbox. When
-- any message arrives for which there are no handlers able to process
-- its content, the 'UnhandledMessagePolicy' will be applied. Sometimes
-- it is desireable to process incoming messages which aren't part of the
-- protocol, rather than let the policy deal with them. This is particularly
-- true when incoming messages are important to the process, but their point
-- of origin is outside the author's control. Handling /signals/ such as
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
--                       (\\(\"timeout\", (d :: Delay)) -> timeoutAfter_ d)
--       ]
--     , timeoutHandler = \\_ _ -> stop $ ExitOther \"timeout\"
--   }
-- @
--
-- [Avoiding Side Effects]
--
-- If you wish to only write side-effect free code in your server definition,
-- then there is an explicit API for doing so. Instead of using the handlers
-- definition functions in this module, import the /pure/ server module instead,
-- which provides a StateT based monad for building referentially transparent
-- callbacks.
--
-- See "Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted" for
-- details and API documentation.
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
-- [Structured Exit Handling]
--
-- Because "Control.Distributed.Process.ProcessExitException" is a ubiquitous
-- signalling mechanism in Cloud Haskell, it is treated unlike other
-- asynchronous exceptions. The 'ProcessDefinition' 'exitHandlers' field
-- accepts a list of handlers that, for a specific exit reason, can decide
-- how the process should respond. If none of these handlers matches the
-- type of @reason@ then the process will exit with @DiedException why@. In
-- addition, a private /exit handler/ is installed for exit signals where
-- @reason :: ExitReason@, which is a form of /exit signal/ used explicitly
-- by the supervision APIs. This behaviour, which cannot be overriden, is to
-- gracefully shut down the process, calling the @shutdownHandler@ as usual,
-- before stopping with @reason@ given as the final outcome.
--
-- /Example: handling custom data is @ProcessExitException@/
--
-- > handleExit  (\state from (sigExit :: SomeExitData) -> continue s)
--
-- Under some circumstances, handling exit signals is perfectly legitimate.
-- Handling of /other/ forms of asynchronous exception (e.g., exceptions not
-- generated by an /exit/ signal) is not supported by this API. Cloud Haskell's
-- primitives for exception handling /will/ work normally in managed process
-- callbacks however.
--
-- If any asynchronous exception goes unhandled, the process will immediately
-- exit without running the @shutdownHandler@. It is very important to note
-- that in Cloud Haskell, link failures generate asynchronous exceptions in
-- the target and these will NOT be caught by the API and will therefore
-- cause the process to exit /without running the termination handler/
-- callback. If your termination handler is set up to do important work
-- (such as resource cleanup) then you should avoid linking you process
-- and use monitors instead.
--
-- [Prioritised Mailboxes]
--
-- Many processes need to prioritise certain classes of message over others,
-- so two subsets of the API are given to supporting those cases.
--
-- A 'PrioritisedProcessDefintion' combines the usual 'ProcessDefintion' -
-- containing the cast/call API, error, termination and info handlers - with a
-- list of 'Priority' entries, which are used at runtime to prioritise the
-- server's inputs. Note that it is only messages which are prioritised; The
-- server's various handlers are still evaluated in insertion order.
--
-- Prioritisation does not guarantee that a prioritised message/type will be
-- processed before other traffic - indeed doing so in a multi-threaded runtime
-- would be very hard - but in the absence of races between multiple processes,
-- if two messages are both present in the process' own mailbox, they will be
-- applied to the ProcessDefinition's handler's in priority order. This is
-- achieved by draining the real mailbox into a priority queue and processing
-- each message in turn.
--
-- A prioritised process must be configured with a 'Priority' list to be of
-- any use. Creating a prioritised process without any priorities would be a
-- big waste of computational resources, and it is worth thinking carefully
-- about whether or not prioritisation is truly necessary in your design before
-- choosing to use it.
--
-- Using a prioritised process is as simple as calling 'pserve' instead of
-- 'serve', and passing an initialised 'PrioritisedProcessDefinition'.
--
-- [Control Channels]
--
-- For advanced users and those requiring very low latency, a prioritised
-- process definition might not be suitable, since it performs considerable
-- work /behind the scenes/. There are also designs that need to segregate a
-- process' /control plane/ from other kinds of traffic it is expected to
-- receive. For such use cases, a /control channel/ may prove a better choice,
-- since typed channels are already prioritised during the mailbox scans that
-- the base @receiveWait@ and @receiveTimeout@ primitives from
-- distribute-process provides.
--
-- In order to utilise a /control channel/ in a server, it must be passed to the
-- corresponding 'handleControlChan' function (or its stateless variant). The
-- control channel is created by evaluating 'newControlChan', in the same way
-- that we create regular typed channels.
--
-- In order for clients to communicate with a server via its control channel
-- however, they must pass a handle to a 'ControlPort', which can be obtained by
-- evaluating 'channelControlPort' on the 'ControlChannel'. A 'ControlPort' is
-- @Serializable@, so they can alternatively be sent to other processes.
--
-- /Control channel/ traffic will only be prioritised over other traffic if the
-- handlers using it are present before others (e.g., @handleInfo, handleCast@,
-- etc) in the process definition. It is not possible to combine prioritised
-- processes with /control channels/. Attempting to do so will satisfy the
-- compiler, but crash with a runtime error once you attempt to evaluate the
-- prioritised server loop (i.e., 'pserve').
--
-- Since the primary purpose of control channels is to simplify and optimise
-- client-server communication over a single channel, this module provides an
-- alternate server loop in the form of 'chanServe'. Instead of passing an
-- initialised 'ProcessDefinition', this API takes an expression from a
-- 'ControlChannel' to 'ProcessDefinition', operating in the 'Process' monad.
-- Providing the opaque reference in this fashion is useful, since the type of
-- messages the control channel carries will not correlate directly to the
-- inter-process traffic we use internally.
--
-- Although control channels are intended for use as a single control plane
-- (via 'chanServe'), it /is/ possible to use them as a more strictly typed
-- communications backbone, since they do enforce absolute type safety in client
-- code, being bound to a particular type on creation. For rpc (i.e., 'call')
-- interaction however, it is not possible to have the server reply to a control
-- channel, since they're a /one way pipe/. It is possible to alleviate this
-- situation by passing a request type than contains a typed channel bound to
-- the expected reply type, enabling client and server to match on both the input
-- and output types as specifically as possible. Note that this still does not
-- guarantee an agreement on types between all parties at runtime however.
--
-- An example of how to do this follows:
--
-- > data Request = Request String (SendPort String)
-- >   deriving (Typeable, Generic)
-- > instance Binary Request where
-- >
-- > -- note that our initial caller needs an mvar to obtain the control port...
-- > echoServer :: MVar (ControlPort Request) -> Process ()
-- > echoServer mv = do
-- >   cc <- newControlChan :: Process (ControlChannel Request)
-- >   liftIO $ putMVar mv $ channelControlPort cc
-- >   let s = statelessProcess {
-- >       apiHandlers = [
-- >            handleControlChan_ cc (\(Request m sp) -> sendChan sp m >> continue_)
-- >          ]
-- >     }
-- >   serve () (statelessInit Infinity) s
-- >
-- > echoClient :: String -> ControlPort Request -> Process String
-- > echoClient str cp = do
-- >   (sp, rp) <- newChan
-- >   sendControlMessage cp $ Request str sp
-- >   receiveChan rp
--
-- [Performance Considerations]
--
-- The various server loops are fairly optimised, but there /is/ a definite
-- cost associated with scanning the mailbox to match on protocol messages,
-- plus additional costs in space and time due to mapping over all available
-- /info handlers/ for non-protocol (i.e., neither /call/ nor /cast/) messages.
-- These are exacerbated significantly when using prioritisation, whilst using
-- a single control channel is very fast and carries little overhead.
--
-- From the client perspective, it's important to remember that the /call/
-- protocol will wait for a reply in most cases, triggering a full O(n) scan of
-- the caller's mailbox. If the mailbox is extremely full and calls are
-- regularly made, this may have a significant impact on the caller. The
-- @callChan@ family of client API functions can alleviate this, by using (and
-- matching on) a private typed channel instead, but the server must be written
-- to accomodate this. Similar gains can be had using a /control channel/ and
-- providing a typed reply channel in the request data, however the 'call'
-- mechanism does not support this notion, so not only are we unable
-- to use the various /reply/ functions, client code should also consider
-- monitoring the server's pid and handling server failures whilst waiting on
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.ManagedProcess
  ( -- * Starting/Running server processes
    InitResult(..)
  , InitHandler
  , serve
  , pserve
  , chanServe
  , runProcess
  , prioritised
    -- * Client interactions
  , module Control.Distributed.Process.Platform.ManagedProcess.Client
    -- * Defining server processes
  , ProcessDefinition(..)
  , PrioritisedProcessDefinition(..)
  , RecvTimeoutPolicy(..)
  , Priority(..)
  , DispatchPriority()
  , Dispatcher()
  , DeferredDispatcher()
  , ShutdownHandler
  , TimeoutHandler
  , ProcessAction(..)
  , ProcessReply
  , Condition
  , CallHandler
  , CastHandler
  , UnhandledMessagePolicy(..)
  , CallRef
  , ControlChannel()
  , ControlPort()
  , defaultProcess
  , defaultProcessWithPriorities
  , statelessProcess
  , statelessInit
    -- * Server side callbacks
  , handleCall
  , handleCallIf
  , handleCallFrom
  , handleCallFromIf
  , handleCast
  , handleCastIf
  , handleInfo
  , handleRaw
  , handleRpcChan
  , handleRpcChanIf
  , action
  , handleDispatch
  , handleExit
    -- * Stateless callbacks
  , handleCall_
  , handleCallFrom_
  , handleCallIf_
  , handleCallFromIf_
  , handleCast_
  , handleCastIf_
  , handleRpcChan_
  , handleRpcChanIf_
    -- * Control channels
  , newControlChan
  , channelControlPort
  , handleControlChan
  , handleControlChan_
    -- * Prioritised mailboxes
  , module Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
    -- * Constructing handler results
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
  , stopWith
  , stop_
  , replyTo
  , replyChan
  ) where

import Control.Distributed.Process hiding (call, Message)
import Control.Distributed.Process.Platform.ManagedProcess.Client
import Control.Distributed.Process.Platform.ManagedProcess.Server
import Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
import Control.Distributed.Process.Platform.ManagedProcess.Internal.GenProcess
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import Control.Distributed.Process.Platform.Internal.Types (ExitReason(..))
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Prelude hiding (init)

-- TODO: automatic registration

-- | Starts the /message handling loop/ for a managed process configured with
-- the supplied process definition, after calling the init handler with its
-- initial arguments. Note that this function does not return until the server
-- exits.
serve :: a
      -> InitHandler a s
      -> ProcessDefinition s
      -> Process ()
serve argv init def = runProcess (recvLoop def) argv init

-- | Starts the /message handling loop/ for a prioritised managed process,
-- configured with the supplied process definition, after calling the init
-- handler with its initial arguments. Note that this function does not return
-- until the server exits.
pserve :: a
       -> InitHandler a s
       -> PrioritisedProcessDefinition s
       -> Process ()
pserve argv init def = runProcess (precvLoop def) argv init

-- | Starts the /message handling loop/ for a managed process, configured with
-- a typed /control channel/. The caller supplied expression is evaluated with
-- an opaque reference to the channel, which must be passed when calling
-- @handleControlChan@. The meaning and behaviour of the init handler and
-- initial arguments are the same as those given to 'serve'. Note that this
-- function does not return until the server exits.
--
chanServe :: (Serializable b)
          => a
          -> InitHandler a s
          -> (ControlChannel b -> Process (ProcessDefinition s))
          -> Process ()
chanServe argv init mkDef = do
  pDef <- mkDef . ControlChannel =<< newChan
  runProcess (recvLoop pDef) argv init

-- | Wraps any /process loop/ and ensures that it adheres to the
-- managed process start/stop semantics, i.e., evaluating the
-- @InitHandler@ with an initial state and delay will either
-- @die@ due to @InitStop@, exit silently (due to @InitIgnore@)
-- or evaluate the process' @loop@. The supplied @loop@ must evaluate
-- to @ExitNormal@, otherwise the calling processing will @die@ with
-- whatever @ExitReason@ is given.
--
runProcess :: (s -> Delay -> Process ExitReason)
           -> a
           -> InitHandler a s
           -> Process ()
runProcess loop args init = do
  ir <- init args
  case ir of
    InitOk s d -> loop s d >>= checkExitType
    InitStop s -> die $ ExitOther s
    InitIgnore -> return ()
  where
    checkExitType :: ExitReason -> Process ()
    checkExitType ExitNormal = return ()
    checkExitType other      = die other

-- | A default 'ProcessDefinition', with no api, info or exit handler.
-- The default 'timeoutHandler' simply continues, the 'shutdownHandler'
-- is a no-op and the 'unhandledMessagePolicy' is @Terminate@.
defaultProcess :: ProcessDefinition s
defaultProcess = ProcessDefinition {
    apiHandlers      = []
  , infoHandlers     = []
  , exitHandlers     = []
  , timeoutHandler   = \s _ -> continue s
  , shutdownHandler  = \_ _ -> return ()
  , unhandledMessagePolicy = Terminate
  } :: ProcessDefinition s

-- | Turns a standard 'ProcessDefinition' into a 'PrioritisedProcessDefinition',
-- by virtue of the supplied list of 'DispatchPriority' expressions.
--
prioritised :: ProcessDefinition s
            -> [DispatchPriority s]
            -> PrioritisedProcessDefinition s
prioritised def ps = PrioritisedProcessDefinition def ps defaultRecvTimeoutPolicy

-- | Sets the default 'recvTimeoutPolicy', which gives up after 10k reads.
defaultRecvTimeoutPolicy :: RecvTimeoutPolicy
defaultRecvTimeoutPolicy = RecvCounter 10000

-- | Creates a default 'PrioritisedProcessDefinition' from a list of
-- 'DispatchPriority'. See 'defaultProcess' for the underlying definition.
defaultProcessWithPriorities :: [DispatchPriority s] -> PrioritisedProcessDefinition s
defaultProcessWithPriorities dps = prioritised defaultProcess dps

-- | A basic, stateless 'ProcessDefinition'. See 'defaultProcess' for the
-- default field values.
statelessProcess :: ProcessDefinition ()
statelessProcess = defaultProcess :: ProcessDefinition ()

-- | A default, state /unaware/ 'InitHandler' that can be used with
-- 'statelessProcess'. This simply returns @InitOk@ with the empty
-- state (i.e., unit) and the given 'Delay'.
statelessInit :: Delay -> InitHandler () ()
statelessInit d () = return $ InitOk () d

