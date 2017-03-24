{-# LANGUAGE ExistentialQuantification  #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.FSM
-- Copyright   :  (c) Tim Watson 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- A /Managed Process/ API for building state machines. Losely based
-- on http://erlang.org/doc/man/gen_statem.html, but with a Haskell-ish
-- flavour.
--
-- A state machine is defined by a "Step" that is executed whenever an input
-- arrives in the process mailbox. This "Step" will usually be produced by
-- evaluating the combinator-style API provided by this module, to link
-- events with actions and transitions that communicate responses back to
-- client processes, alter the state (or state data), and so on.
--
-- [Overview and Examples]
--
-- The "Step" that defines our state machines is parameterised by two types,
-- @s@ and @d@, which represent the state identity (e.g. state name) and
-- state data. These types are fixed, such that if you wish to alternate the
-- type or form state data for different state identities, you will need to
-- encode the relevant storage facilities into the state type @s@ (or choose
-- to align the two types and ensure they are adjusted in tandem yourself).
--
-- The following example shows a simple pushbutton model for a toggling
-- push-button. You can push the button and it replies if it went on or off,
-- and you can ask for a count of how many times the switch has been pushed.
--
-- We begin by defining the types we'll be working with. An algebraic data
-- type for the state (identity), an "Int" as the state data (for holding the
-- counter), and a request datum for issuing a /check/ on the number of times
-- the button has been set to @On@. Pushing the button will be represented
-- by unit.
--
-- > data State = On | Off deriving (Eq, Show, Typeable, Generic)
-- > instance Binary State where
-- >
-- > data Check = Check deriving (Eq, Show, Typeable, Generic)
-- > instance Binary Check where
-- >
-- > type StateData = Integer
-- > type ButtonPush = ()
--
-- We define our starting state as a "Step", which yields the @Off@ state id
-- and an initial counter set to zero.
--
-- > startState :: Step State Integer
-- > startState = yield Off initCount
-- >
-- > initCount :: StateData
-- > initCount = 0
--
-- To capture what happens when a specific event arrives in the mailbox, we
-- evaluate the 'event' function and specify the type it accepts. When combined
-- with 'await', this maps input messages of a specific type to actions and
-- state transitions.
--
-- > await (event :: Event ButtonPush) actions
--
-- Since our @startState@ is going to yield a specific state and data, we don't
-- want it to be evaluated each time we handle a message. The 'begin' function
-- ensures that its first argument is only evaluated once, on our first pass of
-- the state machine's instruction set (i.e. the "Step" structure that determines
-- its runtime execution). Thus we have:
--
-- >  begin startState $ await (event :: Event ButtonPush) actions
--
-- In response to a button push, we want to set the state to it's opposite
-- setting. We behave differently in the two states, so we can't simply write
-- @if state == On then enter Off else enter On@, therefore we will use 'atState'
-- to execute an action only if the current state matches our input.
--
-- > actions = atState On enter Off
--
-- Now of course we need to choose between two states. We could use 'allState'
-- and switch on the state id in our code, but 'pick' provides an API that lets
-- us stay in the combinatorial pattern instead:
--
-- > actions = ((pick (atState On  enter Off))
-- >                  (atState Off (set_ (+1) >> enter On)))
--
-- The 'set_' function alters our state data (used to track the button click to
-- @On@ count), and the 'enter' function produces a "Transition". Transitions
-- can alter the sate id, state data, and/or determine what the server process
-- will do next (e.g. stop, timeout, etc)..
--
-- > atState :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
--
-- Looking at the signature of 'atState', we can see that it takes a state id for
-- comparison, and an action in the "FSM" monad which evaluates to a "Transition".
-- Notice that the 'set_' action does not yield a transition. In fact, 'set' does,
-- but we need to throw it away by using monadic @>>@, so we can introduce the
-- 'enter' transition.
--
-- Essentially this is all syntactic sugar. What happens here is that 'set_'
-- evaluates 'addTransition', which can be used to queue up multiple transitions.
-- So what we really want is @addTransition set (+1) >> addTransition enter On@,
-- however 'atState' wants an action that produces a "Transition", and finishing
-- our /sentence/ with @enter newState@ reads rather nicely, so we've opted for
-- @set (+1) >> enter On@ in the end.
--
-- Only one options presents itself for replying to clients, and that is 'reply'.
-- Since an FSM process deals with control flow quite differently to an ordinary
-- managed process - taking input messages and passing them through the "Step"
-- definitions that operate as a simple state machine - we do not leverage the
-- usual @call@ APIs and instead utilise rpc channels to handle synchronous
-- client/server style interactions with a state machine process.
--
-- Thus we treat replying as a separate "Step", and use 'join' to combine the
-- 'await' "Step" with 'reply' such that we have something akin to
--
-- > (await (event :: Event ButtonPush) actions) `join` (reply currentState))
--
-- Putting this all together, we will now replace 'await', 'atState', 'join' and
-- so on, with their equivalent synonyms, provided as operators to make the
-- combinator pattern style look a bit more like an internal DSL. We end up with:
--
-- > switchFsm :: Step State StateData
-- > switchFsm = startState
-- >          ^. ((event :: Event ButtonPush)
-- >               ~> (  (On  ~@  enter Off))
-- >                  .| (Off ~@ (set_ (+1) >> enter On))
-- >                  ) |> (reply currentState))
--
-- Our client code will need to use the @call@ function from the Client module,
-- although it /is/ possible to interact synchronously with an FSM process (e.g.
-- in client/server mode) by hand, the implementation is very likely to change
-- in a future release and this isn't advised.
--
-- To wire a synchronous @call@ up, we need to supply information about the
-- input and expected response types at the call site. These are used to determine
-- the type of channels used to communicate with the server.
--
-- > pushButton :: ProcessId -> Process State
-- > pushButton pid = call pid (() :: ButtonPush)
--
-- Starting a new switch server process is fairly simple:
--
-- > pid <- start Off initCount switchFsm
--
-- And we can interact with it using our defined function.
--
-- > mSt <- pushButton pid
-- > mSt `shouldBe` equalTo On
-- >
-- > mSt' <- pushButton pid
-- > mSt' `shouldBe` equalTo Off
--
-- However we haven't got a way to query the switched-on count yet. Let's add
-- that now. We will send our @Check@ datum to the server process, and expect
-- an @Int@ reply.
--
-- > switchFsm :: Step State StateData
-- > switchFsm = startState
-- >          ^. ((event :: Event ButtonPush)
-- >               ~> (  (On  ~@ (set_ (+1) >> enter Off)) -- on => off => on is possible with |> here...
-- >                  .| (Off ~@ (set_ (+1) >> enter On))
-- >                  ) |> (reply currentState))
-- >          .| ((event :: Event Check) ~> reply stateData)
-- >
--
-- Notice that we can still use the @(.|)@ operator - a synonym for 'pick' -
-- here, since we're picking between two branches based on the type of the event
-- received. The 'reply' function takes an action in the "FSM" monad, which must
-- evaluate to a "Serializable" type @r@, which is sent back to the client.
--
-- We can now write our check function...
--
-- > check :: ProcessId -> Process StateData
-- > check pid = call pid Check
--
-- This is exactly the same approach that we took with @pushButton@. We can
-- leverage this in our code too, so after we've evaluated the @pushButton@
-- twice (as above), we will see
--
-- > mCk <- check pid
-- > mCk `shouldBe` equalTo (1 :: StateData)
--
-- How do we terminate our FSM process when we're done with it? A process
-- built using this API will respond to exit signals in a matter befitting a
-- managed process, e.g. suitable for use in a supervision tree.
--
-- We can handle exit signals by registering listeners for them, as though they
-- were incoming events. The type we match on must be the type of the /exit reason/
-- (whatever that may be, whether it is "ExitReason" or some other type), not
-- the exception type being thrown.
--
-- Let's play around with this in our button state machine. We will /catch/ an
-- exit where the reason is @ExitNormal@ and instead of stopping, we'll timeout
-- after three seconds and publish a @Reset@ event to ourselves.
--
-- > data Reset = Reset deriving (Eq, Show, Typeable, Generic)
-- > instance Binary Reset where
-- >
-- > switchFsm = startState
-- >          ^. ((event :: Event ButtonPush)
-- >               ~> (  (On  ~@ (set_ (+1) >> enter Off)) -- on => off => on is possible with |> here...
-- >                  .| (Off ~@ (set_ (+1) >> enter On))
-- >                  ) |> (reply currentState))
-- >          .| ((event :: Event ExitReason)
-- >               ~> ((== ExitNormal) ~? (\_ -> timeout (seconds 3) Reset)))
-- >          .| ((event :: Event Check) ~> reply stateData)
-- >          .| (event :: Event Reset)
-- >              ~> (allState $ \Reset -> put initCount >> enter Off)
--
-- Here 'put' works similarly to 'set_' and 'allState' applies the action/transition
-- regardless of the current state. The @condition ~? action@ operator, a synonym
-- for 'matching', will only match if the conditional expression evaluates to
-- @True@. Obviously if the "ExitReason" is something other than @ExitNormal@
-- we will not timeout, and in fact we will not handle the exit signal at all.
--
-- In order to participate properly in a supervision tree, a process should
-- respond to the @ExitShutdown@ "ExitReason" by executing a clean shutdown and
-- stopping normally. What happens if we try to handle this "ExitReason"
-- ourselves?
--
-- > .| ((event :: Event Stop)
-- >      ~> (  ((== ExitNormal) ~? (\_ -> timeout (seconds 3) Reset))
-- >         .| ((== ExitShutdown) ~? (\_ -> timeout (seconds 3) Reset))
-- >         .| ((const True) ~? stop)
-- >         ))
--
-- We've added an expression to always stop when the previous two branches fail,
-- so that even @ExitOther@ will lead to a normal shutdown. Let's test this...
--
-- >  exit pid ExitNormal
-- >  sleep $ seconds 6
-- >  alive <- isProcessAlive pid
-- >  alive `shouldBe` equalTo True
-- >
-- >  exit pid ExitShutdown
-- >  monitor pid >>= waitForDown
-- >  alive' <- isProcessAlive pid
-- >  alive' `shouldBe` equalTo False
--
-- So we can see that our override of @ExitShutdown@ has failed, and this is
-- because any process implemented with the /managed process/ API will respond
-- to @ExitShutdown@ by executing its termination handlers and stopping normally.
--
-- We can add a shutdown handler quite easily, by dealing with the @Stopping@
-- event type, like so:
--
-- > (event :: Event Stopping) ~> actions
--
-- While we're discussing exit signals, let's briefly cover the /safe/ API we
-- have available to us for ensuring that if an exit signal interrupts one of
-- our actions/transitions before it completes, but we handle that exit signal
-- without terminating, that we can re-try handling the event again.
--
-- The 'safeWait' function, and its operator synonym @(*>)@ do precisely this.
-- Let's write up an example and test it.
--
-- > blockingFsm :: SendPort () -> Step State ()
-- > blockingFsm sp = initState Off ()
-- >             ^.  ((event :: Event ())
-- >                 *> (allState $ \() -> (lift $ sleep (seconds 10) >> sendChan sp ()) >> resume))
-- >              .| ((event :: Event Stop)
-- >                 ~> (  ((== ExitNormal)   ~? (\_ -> resume) )
-- >                    .| ((== ExitShutdown) ~? const resume)
-- >                    ))
-- >
-- > verifyMailboxHandling :: Process ()
-- > verifyMailboxHandling = do
-- >   (sp, rp) <- newChan :: Process (SendPort (), ReceivePort ())
-- >   pid <- start Off () (blockingFsm sp)
-- >
-- >   send pid ()
-- >   exit pid ExitNormal
-- >
-- >   sleep $ seconds 5
-- >   alive <- isProcessAlive pid
-- >   alive `shouldBe` equalTo True
-- >
-- >   -- we should resume after the ExitNormal handler runs, and get back into the ()
-- >   -- handler due to safeWait (*>) which adds a `safe` filter check for the given type
-- >   () <- receiveChan rp
-- >
-- >   exit pid ExitShutdown
-- >   monitor pid >>= waitForDown
-- >   alive' <- isProcessAlive pid
-- >   alive' `shouldBe` equalTo False
-- >
--
-- [Prioritising Events and Manipulating the Event Queue]
--
-- We will review these capabilities by example. Our state machine will respond
-- to button clicks by postponing the events when its state id is @Off@. In the
-- other state (i.e. @On@), it will prioritise events passing a new state, and
-- respond to button clicks by pushing them onto a typed channel. In addition,
-- we handle @Event String@ by either putting the event at the back of the total
-- event queue, or putting a @()@ at the front/head of the queue.
--
-- > genFSM :: SendPort () -> Step State ()
-- > genFSM sp = initState Off ()
-- >        ^. ( (whenStateIs Off)
-- >             |> ((event :: Event ()) ~> (always $ \() -> postpone))
-- >           )
-- >        .| ( (((pevent 100) :: Event State) ~> (always $ \state -> enter state))
-- >          .| ((event :: Event ()) ~> (always $ \() -> (lift $ sendChan sp ()) >> resume))
-- >           )
-- >        .| ( (event :: Event String)
-- >              ~> ( (Off ~@ putBack)
-- >                .| (On  ~@ (nextEvent ()))
-- >                 )
-- >           )
--
-- Notice that we're able to apply filters/conditions on both state and event
-- types at the /top level/ of our DSL.
--
-- Our test case will be a bit racy, since we'll be relying on having loaded up
-- a backlog of messages and using priorities to jump the queue.
--
-- > republicationOfEvents :: Process ()
-- > republicationOfEvents = do
-- >   (sp, rp) <- newChan
-- >
-- >   pid <- start Off () $ genFSM sp
-- >
-- >   replicateM_ 15 $ send pid ()
-- >
-- >   Nothing <- receiveChanTimeout (asTimeout $ seconds 5) rp
-- >
-- >   send pid On
-- >
-- >   replicateM_ 15 $ receiveChan rp
-- >
-- >   send pid "hello"  -- triggers `nextEvent ()`
-- >
-- >   res <- receiveChanTimeout (asTimeout $ seconds 5) rp :: Process (Maybe ())
-- >   res `shouldBe` equalTo (Just ())
-- >
-- >   send pid Off
-- >
-- >   forM_ ([1..50] :: [Int]) $ \i -> send pid i
-- >   send pid "yo"
-- >   send pid On
-- >
-- >   res' <- receiveChanTimeout (asTimeout $ seconds 20) rp :: Process (Maybe ())
-- >   res' `shouldBe` equalTo (Just ())
-- >
-- >   kill pid "thankyou byebye"
--
-- Here, the difference between 'postpone' and 'putBack' is that 'postpone' will
-- ensure that the events given to it aren't re-processed until the state id
-- changes. Once the state change is detected, those postponed events are
-- set to be added to the front of the queue (ahead of other events) as soon
-- as the pass completes.
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.FSM
 ( -- * Starting / Running an FSM Process
   start
 , run
   -- * Defining FSM Steps, Actions, and Transitions
 , initState
 , yield
 , event
 , pevent
 , enter
 , resume
 , reply
 , postpone
 , putBack
 , nextEvent
 , publishEvent
 , timeout
 , stop
 , await
 , safeWait
 , whenStateIs
 , pick
 , begin
 , join
 , reverseJoin
 , atState
 , always
 , allState
 , matching
 , set
 , set_
 , put
   -- * DSL-style API (operator sugar)
 , (.|)
 , (|>)
 , (<|)
 , (~>)
 , (*>)
 , (~@)
 , (~?)
 , (^.)
   -- * Useful / Important Types and Utilities
 , Event
 , FSM
 , lift
 , liftIO
 , stateData
 , currentInput
 , currentState
 , currentMessage
 , addTransition
 , Step
 , Transition
 , State
 ) where

import Control.Distributed.Process (wrapMessage)
import Control.Distributed.Process.Extras (ExitReason)
import Control.Distributed.Process.Extras.Time
 ( TimeInterval
 )
import Control.Distributed.Process.ManagedProcess
 ( processState
 , setProcessState
 , runAfter
 )
import Control.Distributed.Process.ManagedProcess.Server.Priority (setPriority)
import Control.Distributed.Process.FSM.Internal.Process
import Control.Distributed.Process.FSM.Internal.Types
import Control.Distributed.Process.Serializable (Serializable)
import Prelude hiding ((*>))

-- | Fluent way to say "yield" when you're building an initial state up (e.g.
-- whilst utilising "begin").
initState :: forall s d . s -> d -> Step s d
initState = yield

-- | Given a state @s@ and state data @d@, set these for the current pass and
-- all subsequent passes.
yield :: forall s d . s -> d -> Step s d
yield = Yield

-- | Creates an @Event m@ for some "Serializable" type @m@. When passed to
-- functions that follow the combinator pattern (such as "await"), will ensure
-- that only messages of type @m@ are processed by the handling expression.
--
event :: (Serializable m) => Event m
event = Wait

-- | A /prioritised/ version of "event". The server will prioritise messages
-- matching the "Event" type @m@.
--
-- See "Control.Distributed.Process.ManagedProcess.Server.Priority" for more
-- details about input prioritisation and prioritised process definitions.
pevent :: (Serializable m) => Int -> Event m
pevent = WaitP . setPriority

-- | Evaluates to a "Transition" that instructs the process to enter the given
-- state @s@. All expressions following evaluation of "enter" will see
-- "currentState" containing the updated value, and any future events will be
-- processed in the new state.
--
-- In addition, should any events/messages have been postponed in a previous
-- state, they will be immediately placed at the head of the queue (in front of
-- received messages) and processed once the current pass has been fully evaluated.
--
enter :: forall s d . s -> FSM s d (Transition s d)
enter = return . Enter

-- | Evaluates to a "Transition" that postpones the current event.
--
-- Postponed events are placed in a temporary queue, where they remain until
-- the current state changes.
--
postpone :: forall s d . FSM s d (Transition s d)
postpone = return Postpone

-- | Evaluates to a "Transition" that places the current input event/message at
-- the back of the process mailbox. The message will be processed again in due
-- course, as the mailbox is processed in priority order.
--
putBack :: forall s d . FSM s d (Transition s d)
putBack = return PutBack

-- | Evaluates to a "Transition" that places the given "Serializable" message
-- at the head of the queue. Once the current pass is fully evaluated, the input
-- will be the next event to be processed unless it is trumped by another input
-- with a greater priority.
--
nextEvent :: forall s d m . (Serializable m) => m -> FSM s d (Transition s d)
nextEvent m = return $ Push (wrapMessage m)

-- | As "nextEvent", but places the message at the back of the queue by default.
--
-- Mailbox priority ordering will still take precedence over insertion order.
--
publishEvent :: forall s d m . (Serializable m) => m -> FSM s d (Transition s d)
publishEvent m = return $ Enqueue (wrapMessage m)

-- | Evaluates to a "Transition" that resumes evaluating the current step.
resume :: forall s d . FSM s d (Transition s d)
resume = return Remain

-- | This /step/ will send a reply to a client process if (and only if) the
-- client provided a reply channel (in the form of @SendPort Message@) when
-- sending its event to the process.
--
-- The expression used to produce the reply message must reside in the "FSM" monad.
-- The reply is /not/ sent immediately upon evaluating "reply", however if the
-- sender supplied a reply channel, the reply is guaranteed to be sent prior to
-- evaluating the next pass.
--
-- No attempt is made to ensure the receiving process is still alive or understands
-- the message - the onus is on the author to ensure the client and server
-- portions of the API understand each other with regard to types.
--
-- No exception handling is applied when evaluating the supplied expression.
reply :: forall s d r . (Serializable r) => FSM s d r -> Step s d
reply = Reply

-- | Given a "TimeInterval" and a "Serializable" event of type @m@, produces a
-- "Transition" that will ensure the event is re-queued after at least
-- @TimeInterval@ has expired.
--
-- The same semantics as "System.Timeout" apply here.
--
timeout :: Serializable m => TimeInterval -> m -> FSM s d (Transition s d)
timeout t m = return $ Eval $ runAfter t m

-- | Produces a "Transition" that when evaluated, will cause the FSM server
-- process to stop with the supplied "ExitReason".
stop :: ExitReason -> FSM s d (Transition s d)
stop = return . Stop

-- | Given a function from @d -> d@, apply it to the current state data.
--
-- This expression functions as a "Transition" and is not applied immediately.
-- To /see/ state data changes in subsequent expressions during a single pass,
-- use "yield" instead.
set :: forall s d . (d -> d) -> FSM s d (Transition s d)
set f = return $ Eval (processState >>= \s -> setProcessState $ s { stData = (f $ stData s) })

set_ :: forall s d . (d -> d) -> FSM s d ()
set_ f = set f >>= addTransition

-- | Set the current state data.
--
-- This expression functions as a "Transition" and is not applied immediately.
-- To /see/ state data changes in subsequent expressions during a single pass,
-- use "yield" instead.
put :: forall s d . d -> FSM s d ()
put d = addTransition $ Eval $ do
  processState >>= \s -> setProcessState $ s { stData = d }

-- | Synonym for "pick"
(.|) :: Step s d -> Step s d -> Step s d
(.|) = Alternate
infixr 9 .|

-- | Pick one of the two "Step"s. Evaluates the LHS first, and proceeds to
-- evaluate the RHS only if the left does not produce a valid result.
pick :: Step s d -> Step s d -> Step s d
pick = Alternate

-- | Synonym for "begin"
(^.) :: Step s d -> Step s d -> Step s d
(^.) = Init
infixr 9 ^.

-- | Provides a means to run a "Step" - the /LHS/ or first argument - only once
-- on initialisation. Subsequent passes will ignore the LHS and run the RHS only.
begin :: Step s d -> Step s d -> Step s d
begin = Init

-- | Synonym for "join".
(|>) :: Step s d -> Step s d -> Step s d
(|>) = Sequence
infixr 9 |>

-- | Join the first and second "Step" by running them sequentially from left to right.
join :: Step s d -> Step s d -> Step s d
join = Sequence

-- | Inverse of "(|>)"
(<|) :: Step s d -> Step s d -> Step s d
(<|) = flip Sequence
-- infixl 9 <|

reverseJoin :: Step s d -> Step s d -> Step s d
reverseJoin = flip Sequence

-- | Synonym for "await"
(~>) :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
(~>) = Await
infixr 9 ~>

-- | For any event that matches the type @m@ of the first argument, evaluate
-- the "Step" given in the second argument.
await :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
await = Await

-- | Synonym for "safeWait"
(*>) :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
(*>) = SafeWait
infixr 9 *>

-- | A /safe/ version of "await". The FSM will place a @check $ safe@ filter
-- around all messages matching the input type @m@ of the "Event" argument.
-- Should an exit signal interrupt the current pass, the input event will be
-- re-tried if an exit handler can be found for the exit-reason.
--
-- In all other respects, this API behaves exactly like "await"
safeWait :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
safeWait = SafeWait

-- | Synonym for "atState"
(~@) :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
(~@) = Perhaps
infixr 9 ~@

-- | Given a state @s@ and an expression that evaluates to a  "Transition",
-- proceed with evaluation only if the "currentState" is equal to @s@.
atState :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
atState = Perhaps

-- | Fluent way to say @atState s resume@.
whenStateIs :: forall s d . (Eq s) => s -> Step s d
whenStateIs s = s ~@ resume

-- | Given an expression from a "Serializable" event @m@ to an expression in the
-- "FSM" monad that produces a "Transition", apply the expression to the current
-- input regardless of what our current state is set to.
allState :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
allState = Always

-- | Synonym for "allState".
always :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
always = Always

-- | Synonym for "matching".
(~?) :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
(~?) = Matching

-- | Given an expression from a "Serializable" input event @m@ to @Bool@, if the
-- expression evaluates to @True@ for the current input, pass the input on to the
-- expression given as the second argument.
matching :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
matching = Matching
