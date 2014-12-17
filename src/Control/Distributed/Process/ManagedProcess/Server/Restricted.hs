{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- A /safe/ variant of the Server Portion of the /Managed Process/ API. Most
-- of these operations have the same names as similar operations in the impure
-- @Server@ module (re-exported by the primary API in @ManagedProcess@). To
-- remove the ambiguity, some combination of either qualification and/or the
-- @hiding@ clause will be required.
--
-- [Restricted Server Callbacks]
--
-- The idea behind this module is to provide /safe/ callbacks, i.e., server
-- code that is free from side effects. This safety is enforced by the type
-- system via the @RestrictedProcess@ monad. A StateT interface is provided
-- for code running in the @RestrictedProcess@ monad, so that server side
-- state can be managed safely without resorting to IO (or code running in
-- the @Process@ monad).
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted
  ( -- * Exported Types
    RestrictedProcess
  , Result(..)
  , RestrictedAction(..)
    -- * Creating call/cast protocol handlers
  , handleCall
  , handleCallIf
  , handleCast
  , handleCastIf
  , handleInfo
  , handleExit
  , handleTimeout
    -- * Handling Process State
  , putState
  , getState
  , modifyState
    -- * Handling responses/transitions
  , reply
  , noReply
  , haltNoReply
  , continue
  , timeoutAfter
  , hibernate
  , stop
    -- * Utilities
  , say
  ) where

import Control.Applicative (Applicative)
import Control.Distributed.Process hiding (call, say)
import qualified Control.Distributed.Process as P (say)
import Control.Distributed.Process.Platform.Internal.Types
  (ExitReason(..))
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server as Server
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Prelude hiding (init)

import Control.Monad.IO.Class (MonadIO)
import qualified Control.Monad.State as ST
  ( MonadState
  , MonadTrans
  , StateT
  , get
  , lift
  , modify
  , put
  , runStateT
  )

import Data.Typeable

-- | Restricted (i.e., pure, free from side effects) execution
-- environment for call/cast/info handlers to execute in.
--
newtype RestrictedProcess s a = RestrictedProcess {
    unRestricted :: ST.StateT s Process a
  }
  deriving (Functor, Monad, ST.MonadState s, MonadIO, Typeable, Applicative)

-- | The result of a 'call' handler's execution.
data Result a =
    Reply     a              -- ^ reply with the given term
  | Timeout   Delay a        -- ^ reply with the given term and enter timeout
  | Hibernate TimeInterval a -- ^ reply with the given term and hibernate
  | Stop      ExitReason     -- ^ stop the process with the given reason
  deriving (Typeable)

-- | The result of a safe 'cast' handler's execution.
data RestrictedAction =
    RestrictedContinue               -- ^ continue executing
  | RestrictedTimeout   Delay        -- ^ timeout if no messages are received
  | RestrictedHibernate TimeInterval -- ^ hibernate (i.e., sleep)
  | RestrictedStop      ExitReason   -- ^ stop/terminate the server process

--------------------------------------------------------------------------------
-- Handling state in RestrictedProcess execution environments                 --
--------------------------------------------------------------------------------

-- | Log a trace message using the underlying Process's @say@
say :: String -> RestrictedProcess s ()
say msg = lift . P.say $ msg

-- | Get the current process state
getState :: RestrictedProcess s s
getState = ST.get

-- | Put a new process state state
putState :: s -> RestrictedProcess s ()
putState = ST.put

-- | Apply the given expression to the current process state
modifyState :: (s -> s) -> RestrictedProcess s ()
modifyState = ST.modify

--------------------------------------------------------------------------------
-- Generating replies and state transitions inside RestrictedProcess          --
--------------------------------------------------------------------------------

-- | Instructs the process to send a reply and continue running.
reply :: forall s r . (Serializable r) => r -> RestrictedProcess s (Result r)
reply = return . Reply

-- | Continue without giving a reply to the caller - equivalent to 'continue',
-- but usable in a callback passed to the 'handleCall' family of functions.
noReply :: forall s r . (Serializable r)
           => Result r
           -> RestrictedProcess s (Result r)
noReply r = return r

-- | Halt process execution during a call handler, without paying any attention
-- to the expected return type.
haltNoReply :: forall s r . (Serializable r)
           => ExitReason
           -> RestrictedProcess s (Result r)
haltNoReply r = noReply (Stop r)

-- | Instructs the process to continue running and receiving messages.
continue :: forall s . RestrictedProcess s RestrictedAction
continue = return RestrictedContinue

-- | Instructs the process loop to wait for incoming messages until 'Delay'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @Delay@ will remain in use until changed.
timeoutAfter :: forall s. Delay -> RestrictedProcess s RestrictedAction
timeoutAfter d = return $ RestrictedTimeout d

-- | Instructs the process to /hibernate/ for the given 'TimeInterval'. Note
-- that no messages will be removed from the mailbox until after hibernation has
-- ceased. This is equivalent to evaluating @liftIO . threadDelay@.
--
hibernate :: forall s. TimeInterval -> RestrictedProcess s RestrictedAction
hibernate d = return $ RestrictedHibernate d

-- | Instructs the process to terminate, giving the supplied reason. If a valid
-- 'shutdownHandler' is installed, it will be called with the 'ExitReason'
-- returned from this call, along with the process state.
stop :: forall s. ExitReason -> RestrictedProcess s RestrictedAction
stop r = return $ RestrictedStop r

--------------------------------------------------------------------------------
-- Wrapping handler expressions in Dispatcher and DeferredDispatcher          --
--------------------------------------------------------------------------------

-- | A version of "Control.Distributed.Process.Platform.ManagedProcess.Server.handleCall"
-- that takes a handler which executes in 'RestrictedProcess'.
--
handleCall :: forall s a b . (Serializable a, Serializable b)
           => (a -> RestrictedProcess s (Result b))
           -> Dispatcher s
handleCall = handleCallIf $ Server.state (const True)

-- | A version of "Control.Distributed.Process.Platform.ManagedProcess.Server.handleCallIf"
-- that takes a handler which executes in 'RestrictedProcess'.
--
handleCallIf :: forall s a b . (Serializable a, Serializable b)
             => (Condition s a)
             -> (a -> RestrictedProcess s (Result b))
             -> Dispatcher s
handleCallIf cond h = Server.handleCallIf cond (wrapCall h)

-- | A version of "Control.Distributed.Process.Platform.ManagedProcess.Server.handleCast"
-- that takes a handler which executes in 'RestrictedProcess'.
--
handleCast :: forall s a . (Serializable a)
           => (a -> RestrictedProcess s RestrictedAction)
           -> Dispatcher s
handleCast = handleCastIf (Server.state (const True))

-- | A version of "Control.Distributed.Process.Platform.ManagedProcess.Server.handleCastIf"
-- that takes a handler which executes in 'RestrictedProcess'.
--
handleCastIf :: forall s a . (Serializable a)
                => Condition s a -- ^ predicate that must be satisfied for the handler to run
                -> (a -> RestrictedProcess s RestrictedAction)
                -- ^ an action yielding function over the process state and input message
                -> Dispatcher s
handleCastIf cond h = Server.handleCastIf cond (wrapHandler h)

-- | A version of "Control.Distributed.Process.Platform.ManagedProcess.Server.handleInfo"
-- that takes a handler which executes in 'RestrictedProcess'.
--
handleInfo :: forall s a. (Serializable a)
           => (a -> RestrictedProcess s RestrictedAction)
           -> DeferredDispatcher s
-- cast and info look the same to a restricted process
handleInfo h = Server.handleInfo (wrapHandler h)

handleExit :: forall s a. (Serializable a)
           => (a -> RestrictedProcess s RestrictedAction)
           -> ExitSignalDispatcher s
handleExit h = Server.handleExit $ \s _ a -> (wrapHandler h) s a

handleTimeout :: forall s . (Delay -> RestrictedProcess s RestrictedAction)
                         -> TimeoutHandler s
handleTimeout h = \s d -> do
  (r, s') <- runRestricted s (h d)
  case r of
    RestrictedContinue       -> Server.continue s'
    (RestrictedTimeout   i)  -> Server.timeoutAfter i s'
    (RestrictedHibernate i)  -> Server.hibernate    i s'
    (RestrictedStop      r') -> Server.stop r'

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

wrapHandler :: forall s a . (Serializable a)
            => (a -> RestrictedProcess s RestrictedAction)
            -> s
            -> a
            -> Process (ProcessAction s)
wrapHandler h s a = do
  (r, s') <- runRestricted s (h a)
  case r of
    RestrictedContinue       -> Server.continue s'
    (RestrictedTimeout   i)  -> Server.timeoutAfter i s'
    (RestrictedHibernate i)  -> Server.hibernate    i s'
    (RestrictedStop      r') -> Server.stop r'

wrapCall :: forall s a b . (Serializable a, Serializable b)
            => (a -> RestrictedProcess s (Result b))
            -> s
            -> a
            -> Process (ProcessReply b s)
wrapCall h s a = do
  (r, s') <- runRestricted s (h a)
  case r of
    (Reply       r') -> Server.reply r' s'
    (Timeout   i r') -> Server.timeoutAfter i s' >>= Server.replyWith r'
    (Hibernate i r') -> Server.hibernate    i s' >>= Server.replyWith r'
    (Stop      r'' ) -> Server.stop r''          >>= Server.noReply

runRestricted :: s -> RestrictedProcess s a -> Process (a, s)
runRestricted state proc = ST.runStateT (unRestricted proc) state

-- | TODO MonadTrans instance? lift :: (Monad m) => m a -> t m a
lift :: Process a -> RestrictedProcess s a
lift p = RestrictedProcess $ ST.lift p

