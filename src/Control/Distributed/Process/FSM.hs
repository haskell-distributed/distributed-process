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
-- A /Managed Process/ API for building finite state machines. Losely based
-- on http://erlang.org/doc/man/gen_statem.html, but with a Haskell-ish
-- flavour.
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
set :: forall s d . (d -> d) -> FSM s d ()
set f = addTransition $ Eval $ do
  -- MP.liftIO $ putStrLn "setting state"
  processState >>= \s -> setProcessState $ s { stData = (f $ stData s) }

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
