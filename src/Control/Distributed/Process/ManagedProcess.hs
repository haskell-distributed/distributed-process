{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.ManagedProcess
-- Copyright   :  (c) Tim Watson 2012 - 2017
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
-- supervisor API in distributed-process-supervision.
--
-- [API Overview For The Impatient]
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
-- optional timeout, sleeping for a while, or stopping. The optional timeout
-- behaves a little differently to the other process actions: If no messages
-- are received within the specified time span, a user defined 'timeoutHandler'
-- will be called in order to determine the next action.
--
-- The 'ProcessDefinition' type also defines a @shutdownHandler@,
-- which is called whenever the process exits, whether because a callback has
-- returned 'stop' as the next action, or as the result of unhandled exit signal
-- or similar asynchronous exceptions thrown in (or to) the process itself.
--
-- The handlers are split into groups: /apiHandlers/, /infoHandlers/, and
-- /extHandlers/.
--
-- [Seriously, TL;DR]
--
-- Use 'serve' for a process that sits reading its mailbox and generally behaves
-- as you'd expect. Use 'pserve' and 'PrioritisedProcessDefinition' for a server
-- that manages its mailbox more comprehensively and handles errors a bit differently.
-- Both use the same client API.
--
-- DO NOT mask in handler code, unless you can guarantee it won't be long
-- running and absolutely won't block kill signals from a supervisor.
--
-- Do look at the various API offerings, as there are several, at different
-- levels of abstraction.
--
-- [Managed Process Mailboxes]
--
-- Managed processes come in two flavours, with different runtime characteristics
-- and (to some extent) semantics. These flavours are differentiated by the way
-- in which they handle the server process mailbox - all client interactions
-- remain the same.
--
-- The /vanilla/ managed process mailbox, provided by the 'serve' API, is roughly
-- akin to a tail recursive /listen/ function that calls a list of passed in
-- matchers. We might naively implement it roughly like this:
--
-- >
-- > loop :: stateT -> [(stateT -> Message -> Maybe stateT)] -> Process ()
-- > loop state handlers = do
-- >   st2 <- receiveWait $ map (\d -> handleMessage (d state)) handlers
-- >   case st2 of
-- >     Nothing -> {- we're done serving -} return ()
-- >     Just s2 -> loop s2 handlers
-- >
--
-- Obviously all the details have been ellided, but this is the essential premise
-- behind a /managed process loop/. The process keeps reading from its mailbox
-- indefinitely, until either a handler instructs it to stop, or an asynchronous
-- exception (or exit signal - in the form of an async @ProcessExitException@)
-- terminates it. This kind of mailbox has fairly intuitive runtime characteristics
-- compared to a /plain server process/ (i.e. one implemented without the use of
-- this library): messages will pile up in its mailbox whilst handlers are
-- running, and each handler will be checked against the mailbox based on the
-- type of messages it recognises. We can potentially end up scanning a very
-- large mailbox trying to match each handler, which can be a performance
-- bottleneck depending on expected traffic patterns.
--
-- For most simple server processes, this technique works well and is easy to
-- reason about a use. See the sections on error and exit handling later on for
-- more details about 'serve' based managed processes.
--
-- [Prioritised Mailboxes]
--
-- A prioritised mailbox serves two purposes. The first of these is to allow a
-- managed process author to specify that certain classes of message should be
-- prioritised by the server loop. This is achieved by draining the /real/
-- process mailbox into an internal priority queue, and running the server's
-- handlers repeatedly over its contents, which are dequeued in priority order.
-- The obvious consequence of this approach leads to the second purpose (or the
-- accidental side effect, depending on your point of view) of a prioritised
-- mailbox, which is that we avoid scanning a large mailbox when searching for
-- messages that match the handlers we anticipate running most frequently (or
-- those messages that we deem most important).
--
-- There are several consequences to this approach. One is that we do quite a bit
-- more work to manage the process mailbox behind the scenes, therefore we have
-- additional space overhead to consider (although we are also reducing the size
-- of the mailbox, so there is some counter balance here). The other is that if
-- we do not see the anticipated traffic patterns at runtime, then we might
-- spend more time attempting to prioritise infrequent messages than we would
-- have done simply receiving them! We do however, gain a degree of safety with
-- regards message loss that the 'serve' based /vanilla/ mailbox cannot offer.
-- See the sections on error and exit handling later on for more details about
-- these.
--
-- A Prioritised 'pserve' loop maintains its internal state - including the user
-- defined /server state/ - in an @IORef@, ensuring it is held consistently
-- between executions, even in the face of unhandled exceptions.
--
-- [Defining Prioritised Process Definitions]
--
-- A 'PrioritisedProcessDefintion' combines the usual 'ProcessDefintion' -
-- containing the cast/call API, error, termination and info handlers - with a
-- list of 'Priority' entries, which are used at runtime to prioritise the
-- server's inputs. Note that it is only messages which are prioritised; The
-- server's various handlers are still evaluated in the order in which they
-- are specified in the 'ProcessDefinition'.
--
-- Prioritisation does not guarantee that a prioritised message/type will be
-- processed before other traffic - indeed doing so in a multi-threaded runtime
-- would be very hard - but in the absence of races between multiple processes,
-- if two messages are both present in the process' own mailbox, they will be
-- applied to the ProcessDefinition's handlers in priority order.
--
-- A prioritised process should probably be configured with a 'Priority' list to
-- be useful. Creating a prioritised process without any priorities could be a
-- potential waste of computational resources, and it is worth thinking carefully
-- about whether or not prioritisation is truly necessary in your design before
-- choosing to use it.
--
-- Using a prioritised process is as simple as calling 'pserve' instead of
-- 'serve', and passing an initialised 'PrioritisedProcessDefinition'.
--
-- [The Cast and Call Protocols]
--
-- Deliberate interactions with a /managed process/ usually falls into one of
-- two categories. A 'cast' interaction involves a client sending a message
-- asynchronously and the server handling this input. No reply is sent to
-- the client. On the other hand, a 'call' is a /remote procedure call/,
-- where the client sends a message and waits for a reply from the server.
--
-- All expressions given to @apiHandlers@ have to conform to the /cast or call/
-- protocol. The protocol (messaging) implementation is hidden from the user;
-- API functions for creating user defined @apiHandlers@ are given instead,
-- which take expressions (i.e., a function or lambda expression) and create the
-- appropriate @Dispatcher@ for handling the cast (or call).
--
-- These cast and call protocols are for dealing with /expected/ inputs. They
-- will usually form the explicit public API for the process, and be exposed by
-- providing module level functions that defer to the cast or call client API,
-- giving the process author an opportunity to enforce the correct input and
-- response types. For example:
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
-- entire protocol to be supported in excruciating detail. For that, we would
-- want /session types/, which are beyond the scope of this library.
--
-- [Handling Unexpected/Info Messages]
--
-- An explicit protocol for communicating with the process can be
-- configured using 'cast' and 'call', but it is not possible to prevent
-- other kinds of messages from being sent to the process mailbox. When
-- any message arrives for which there are no handlers able to process
-- its content, the 'UnhandledMessagePolicy' will be applied. Sometimes
-- it is desirable to process incoming messages which aren't part of the
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
-- then there is an explicit API for doing so. Instead of using the handler
-- definition functions in this module, import the /pure/ server module instead,
-- which provides a StateT based monad for building referentially transparent
-- callbacks.
--
-- See "Control.Distributed.Process.ManagedProcess.Server.Restricted" for
-- details and API documentation.
--
-- [Handling Errors]
--
-- Error handling appears in several contexts and process definitions can
-- hook into these with relative ease. Catching exceptions inside handle
-- functions is no different to ordinary exception handling in monadic code.
--
-- @
--   handleCall (\\x y ->
--                catch (hereBeDragons x y)
--                      (\\(e :: SmaugTheTerribleException) ->
--                           return (Left (show e))))
-- @
--
-- The caveats mentioned in "Control.Distributed.Process.Extras" about
-- exit signal handling are very important here - it is strongly advised that
-- you do not catch exceptions of type @ProcessExitException@ unless you plan
-- to re-throw them again.
--
-- [Structured Exit Handling]
--
-- Because "Control.Distributed.Process.ProcessExitException" is a ubiquitous
-- signalling mechanism in Cloud Haskell, it is treated unlike other
-- asynchronous exceptions. The 'ProcessDefinition' 'exitHandlers' field
-- accepts a list of handlers that, for a specific exit reason, can decide
-- how the process should respond. If none of these handlers matches the
-- type of @reason@ then the process will exit. with @DiedException why@. In
-- addition, a private /exit handler/ is installed for exit signals where
-- @(reason :: ExitReason) == ExitShutdown@, which is an of /exit signal/ used
-- explicitly by supervision APIs. This behaviour, which cannot be overriden, is
-- to gracefully shut down the process, calling the @shutdownHandler@ as usual,
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
-- callbacks, but you are strongly advised against swallowing exceptions in
-- general, or masking, unless you have carefully considered the consequences.
--
-- [Different Mailbox Types and Exceptions: Message Loss]
--
-- Neither the /vanilla/ nor the /prioritised/ mailbox implementations will
-- allow you to handle arbitrary asynchronous exceptions outside of your handler
-- code. The way in which the two mailboxes handle unexpected asynchronous
-- exceptions differs significantly however. The first consideration pertains to
-- potential message loss.
--
-- Consider a plain Cloud Haskell expression such as the following:
--
-- @
--   catch (receiveWait [ match (\(m :: SomeType) -> doSomething m) ])
--         (\(e :: SomeCustomAsyncException) -> handleExFrom e pid)
-- @
--
-- It is entirely possible that @receiveWait@ will succeed in matching a message
-- of type @SomeType@ from the mailbox and removing it, to be handed to the
-- supplied expression @doSomething@. Should an asynchronous exception arrive
-- at this moment in time, though the handler might run and allow the server to
-- recover, the message will be permanently lost.
--
-- The mailbox exposed by 'serve' operates in exactly this way, and as such it
-- is advisible to avoid swallowing asynchronous exceptions, since doing so can
-- introduce the possibility of unexpected message loss.
--
-- The prioritised mailbox exposed by 'pserve' on the other hand, does not suffer
-- this scenario. Whilst the mailbox is drained into the internal priority queue,
-- asynchronous exceptions are masked, and only once the queue has been updated
-- are they removed. In addition, it is possible to @peek@ at the priority queue
-- without removing a message, thereby ensuring that should the handler fail or
-- an asynchronous exception arrive whilst processing the message, we can resume
-- handling our message immediately upon recovering from the exception. This
-- behaviour allows the process to guarantee against message loss, whilst avoiding
-- masking within handlers, which is generally bad form (and can potentially lead
-- to zombie processes, when supervised servers refuse to respond to @kill@
-- signals whilst stuck in a long running handler).
--
-- Also note that a process' internal state is subject to the same semantics,
-- such that the arrival of an asynchronous exception (including exit signals!)
-- can lead to handlers (especially exit and shutdown handlers) running with
-- a stale version of their state. For this reason - since we cannot guarantee
-- an up to date state in the presence of these semantics - a shutdown handler
-- for a 'serve' loop will always have its state passed as @LastKnown stateT@.
--
-- [Different Mailbox Types and Exceptions: Error Recovery And Shutdown]
--
-- If any asynchronous exception goes unhandled by a /vanilla/ process, the
-- server will immediately exit without running the user supplied @shutdownHandler@.
-- It is very important to note that in Cloud Haskell, link failures generate
-- asynchronous exceptions in the target and these will NOT be caught by the 'serve'
-- API and will therefore cause the process to exit /without running the
-- termination handler/ callback. If your termination handler is set up to do
-- important work (such as resource cleanup) then you should avoid linking you
-- process and use monitors instead. If your code absolutely must run its
-- termination handlers in the face of any unhandled (async) exception, consider
-- using a prioritised mailbox, which handles this. Alternatively, consider
-- arranging your processes in a supervision tree, and using a shutdown strategy
-- to ensure that siblings terminate cleanly (based off a supervisor's ordered
-- shutdown signal) in order to ensure cleanup code can run reliably.
--
-- As mentioned above, a prioritised mailbox behaves differently in the face
-- of unhandled asynchronous exceptions. Whilst 'pserve' still offers no means
-- for handling arbitrary async exceptions outside your handlers - and you should
-- avoid handling them within, to the maximum extent possible - it does execute
-- its receiving process in such a way that any unhandled exception will be
-- caught and rethrown. Because of this, and the fact that a prioritised process
-- manages its internal state in an @IORef@, shutdown handlers are guaranteed
-- to run even in the face of async exceptions. These are run with the latest
-- version of the server state available, given as @CleanShutdown stateT@ when
-- the process is terminating normally (i.e. for reasons @ExitNormal@ or
-- @ExitShutdown@), and @LastKnown stateT@ when an exception terminated the
-- server process abruptly. The latter acknowledges that we cannot guarantee
-- the exception did not interrupt us after the last handler ran and returned an
-- updated state, but prior to storing the update.
--
-- Although shutdown handlers are run even in the face of unhandled exceptions
-- (and prior to re-throwing, when there is one present), they are not run in a
-- masked state. In fact, exceptions are explicitly unmasked prior to executing
-- a handler, therefore it is possible for a shutdown handler to terminate
-- abruptly. Once again, supervision hierarchies are a better way to ensure
-- consistent cleanup occurs when valued resources are held by a process.
--
-- [Special Clients: Control Channels]
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
-- [Communicating with the outside world: External (STM) Input Channels]
--
-- Both client and server APIs provide a mechanism for interacting with a running
-- server process via STM. This is primarily intended for code that runs outside
-- of Cloud Haskell's /Process/ monad, but can also be used as a channel for
-- sending and/or receiving non-serializable data to or from a managed process.
-- Obviously if you attempt to do this across a remote boundary, things will go
-- spectacularly wrong. The APIs provided do not attempt to restrain this, or
-- to impose any particular scheme on the programmer, therefore you're on your
-- own when it comes to writing the /STM/ code for reading and writing data
-- between client and server.
--
-- For code running inside the /Process/ monad and passing Serializable thunks,
-- there is no real advantage to this approach, and indeed there are several
-- serious disadvantages - none of Cloud Haskell's ordering guarantees will hold
-- when passing data to and from server processes in this fashion, nor are there
-- any guarantees the runtime system can make with regards interleaving between
-- messages passed across Cloud Haskell's communication fabric vs. data shared
-- via STM. This is true even when client(s) and server(s) reside on the same
-- local node.
--
--
-- A server wishing to receive data via STM can do so using the @handleExternal@
-- API. By way of example, here is a simple echo server implemented using STM:
--
-- > demoExternal = do
-- >   inChan <- liftIO newTQueueIO
-- >   replyQ <- liftIO newTQueueIO
-- >   let procDef = statelessProcess {
-- >                     apiHandlers = [
-- >                       handleExternal
-- >                         (readTQueue inChan)
-- >                         (\s (m :: String) -> do
-- >                             liftIO $ atomically $ writeTQueue replyQ m
-- >                             continue s)
-- >                     ]
-- >                     }
-- >   let txt = "hello 2-way stm foo"
-- >   pid <- spawnLocal $ serve () (statelessInit Infinity) procDef
-- >   echoTxt <- liftIO $ do
-- >     -- firstly we write something that the server can receive
-- >     atomically $ writeTQueue inChan txt
-- >     -- then sit and wait for it to write something back to us
-- >     atomically $ readTQueue replyQ
-- >
-- >   say (show $ echoTxt == txt)
--
-- For request/reply channels such as this, a convenience based on the call API
-- is also provided, which allows the server author to write an ordinary call
-- handler, and the client author to utilise an API that monitors the server and
-- does the usual stuff you'd expect an RPC style client to do. Here is another
-- example of this in use, demonstrating the @callSTM@ and @handleCallExternal@
-- APIs in practise.
--
-- > data StmServer = StmServer { serverPid  :: ProcessId
-- >                            , writerChan :: TQueue String
-- >                            , readerChan :: TQueue String
-- >                            }
-- >
-- > instance Resolvable StmServer where
-- >   resolve = return . Just . serverPid
-- >
-- > echoStm :: StmServer -> String -> Process (Either ExitReason String)
-- > echoStm StmServer{..} = callSTM serverPid
-- >                                 (writeTQueue writerChan)
-- >                                 (readTQueue  readerChan)
-- >
-- > launchEchoServer :: CallHandler () String String -> Process StmServer
-- > launchEchoServer handler = do
-- >   (inQ, replyQ) <- liftIO $ do
-- >     cIn <- newTQueueIO
-- >     cOut <- newTQueueIO
-- >     return (cIn, cOut)
-- >
-- >   let procDef = statelessProcess {
-- >                   apiHandlers = [
-- >                     handleCallExternal
-- >                       (readTQueue inQ)
-- >                       (writeTQueue replyQ)
-- >                       handler
-- >                   ]
-- >                 }
-- >
-- >   pid <- spawnLocal $ serve () (statelessInit Infinity) procDef
-- >   return $ StmServer pid inQ replyQ
-- >
-- > testExternalCall :: TestResult Bool -> Process ()
-- > testExternalCall result = do
-- >   let txt = "hello stm-call foo"
-- >   srv <- launchEchoServer (\st (msg :: String) -> reply msg st)
-- >   echoStm srv txt >>= stash result . (== Right txt)
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

module Control.Distributed.Process.ManagedProcess
  ( -- * Starting/Running server processes
    InitResult(..)
  , InitHandler
  , serve
  , pserve
  , chanServe
  , runProcess
  , prioritised
    -- * Client interactions
  , module Control.Distributed.Process.ManagedProcess.Client
    -- * Defining server processes
  , ProcessDefinition(..)
  , PrioritisedProcessDefinition(..)
  , RecvTimeoutPolicy(..)
  , Priority()
  , DispatchPriority()
  , ShutdownHandler
  , TimeoutHandler
  , Condition
  , Action
  , ProcessAction()
  , Reply
  , ProcessReply()
  , ActionHandler
  , CallHandler
  , CastHandler
  , StatelessHandler
  , DeferredCallHandler
  , StatelessCallHandler
  , InfoHandler
  , ChannelHandler
  , StatelessChannelHandler
  , UnhandledMessagePolicy(..)
  , CallRef
  , ExitState(..)
  , isCleanShutdown
  , exitState
  , defaultProcess
  , defaultProcessWithPriorities
  , statelessProcess
  , statelessInit
    -- * Server side callbacks
  , module Control.Distributed.Process.ManagedProcess.Server
    -- * Control channels
  , ControlChannel()
  , ControlPort()
  , newControlChan
  , channelControlPort
    -- * Prioritised mailboxes
  , module P
  ) where

import Control.Distributed.Process hiding (call, Message)
import Control.Distributed.Process.ManagedProcess.Client
import Control.Distributed.Process.ManagedProcess.Server
import qualified Control.Distributed.Process.ManagedProcess.Server.Priority as P hiding (reject)
import Control.Distributed.Process.ManagedProcess.Internal.GenProcess
import Control.Distributed.Process.ManagedProcess.Internal.Types hiding (runProcess)
import Control.Distributed.Process.Extras (ExitReason(..))
import Control.Distributed.Process.Extras.Time
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
    checkExitType ExitNormal   = return ()
    checkExitType ExitShutdown = return ()
    checkExitType other        = die other

-- | A default 'ProcessDefinition', with no api, info or exit handler.
-- The default 'timeoutHandler' simply continues, the 'shutdownHandler'
-- is a no-op and the 'unhandledMessagePolicy' is @Terminate@.
defaultProcess :: ProcessDefinition s
defaultProcess = ProcessDefinition {
    apiHandlers      = []
  , infoHandlers     = []
  , externHandlers   = []
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
prioritised def ps =
  PrioritisedProcessDefinition def ps [] defaultRecvTimeoutPolicy

-- | Sets the default 'recvTimeoutPolicy', which gives up after 10k reads.
defaultRecvTimeoutPolicy :: RecvTimeoutPolicy
defaultRecvTimeoutPolicy = RecvMaxBacklog 10000

-- | Creates a default 'PrioritisedProcessDefinition' from a list of
-- 'DispatchPriority'. See 'defaultProcess' for the underlying definition.
defaultProcessWithPriorities :: [DispatchPriority s] -> PrioritisedProcessDefinition s
defaultProcessWithPriorities = prioritised defaultProcess

-- | A basic, stateless 'ProcessDefinition'. See 'defaultProcess' for the
-- default field values.
statelessProcess :: ProcessDefinition ()
statelessProcess = defaultProcess :: ProcessDefinition ()

-- | A default, state /unaware/ 'InitHandler' that can be used with
-- 'statelessProcess'. This simply returns @InitOk@ with the empty
-- state (i.e., unit) and the given 'Delay'.
statelessInit :: Delay -> InitHandler () ()
statelessInit d () = return $ InitOk () d
