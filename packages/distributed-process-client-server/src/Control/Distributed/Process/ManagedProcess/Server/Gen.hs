{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE AllowAmbiguousTypes        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.ManagedProcess.Server.Priority
-- Copyright   :  (c) Tim Watson 2012 - 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Server Portion of the /Managed Process/ API, as presented by the
-- 'GenProcess' monad. These functions are generally intended for internal
-- use, but the API is relatively stable and therefore they have been re-exported
-- here for general use. Note that if you modify a process' internal state
-- (especially that of the internal priority queue) then you are responsible for
-- any alteratoin that makes to the semantics of your processes behaviour.
--
-- See "Control.Distributed.Process.ManagedProcess.Internal.GenProcess"
-----------------------------------------------------------------------------
module Control.Distributed.Process.ManagedProcess.Server.Gen
  ( -- * Server actions
    reply
  , replyWith
  , noReply
  , continue
  , timeoutAfter
  , hibernate
  , stop
  , reject
  , rejectWith
  , become
  , haltNoReply
  , lift
  , Gen.recvLoop
  , Gen.precvLoop
  , Gen.currentTimeout
  , Gen.systemTimeout
  , Gen.drainTimeout
  , Gen.processState
  , Gen.processDefinition
  , Gen.processFilters
  , Gen.processUnhandledMsgPolicy
  , Gen.processQueue
  , Gen.gets
  , Gen.getAndModifyState
  , Gen.modifyState
  , Gen.setUserTimeout
  , Gen.setProcessState
  , GenProcess
  , Gen.peek
  , Gen.push
  , Gen.enqueue
  , Gen.dequeue
  , Gen.addUserTimer
  , Gen.removeUserTimer
  , Gen.eval
  , Gen.act
  , Gen.runAfter
  , Gen.evalAfter
  ) where

import Control.Distributed.Process.Extras
 ( ExitReason
 )
import Control.Distributed.Process.Extras.Time
 ( TimeInterval
 , Delay
 )
import Control.Distributed.Process.ManagedProcess.Internal.Types
 ( lift
 , ProcessAction(..)
 , GenProcess
 , ProcessReply(..)
 , ProcessDefinition
 )
import qualified Control.Distributed.Process.ManagedProcess.Internal.GenProcess as Gen
 ( recvLoop
 , precvLoop
 , currentTimeout
 , systemTimeout
 , drainTimeout
 , processState
 , processDefinition
 , processFilters
 , processUnhandledMsgPolicy
 , processQueue
 , gets
 , getAndModifyState
 , modifyState
 , setUserTimeout
 , setProcessState
 , GenProcess
 , peek
 , push
 , enqueue
 , dequeue
 , addUserTimer
 , removeUserTimer
 , eval
 , act
 , runAfter
 , evalAfter
 )
import Control.Distributed.Process.ManagedProcess.Internal.GenProcess
 ( processState
 )
import qualified Control.Distributed.Process.ManagedProcess.Server as Server
 ( replyWith
 , continue
 )
import Control.Distributed.Process.Serializable (Serializable)

-- | Reject the message we're currently handling.
reject :: forall r s . String -> GenProcess s (ProcessReply r s)
reject rs = processState >>= \st -> lift $ Server.continue st >>= return . ProcessReject rs

-- | Reject the message we're currently handling, giving an explicit reason.
rejectWith :: forall r m s . (Show r) => r -> GenProcess s (ProcessReply m s)
rejectWith rs = reject (show rs)

-- | Instructs the process to send a reply and continue running.
reply :: forall r s . (Serializable r) => r -> GenProcess s (ProcessReply r s)
reply r = processState >>= \s -> lift $ Server.continue s >>= Server.replyWith r

-- | Instructs the process to send a reply /and/ evaluate the 'ProcessAction'.
replyWith :: forall r s . (Serializable r)
         => r
         -> ProcessAction s
         -> GenProcess s (ProcessReply r s)
replyWith r s = return $ ProcessReply r s

-- | Instructs the process to skip sending a reply /and/ evaluate a 'ProcessAction'
noReply :: (Serializable r) => ProcessAction s -> GenProcess s (ProcessReply r s)
noReply = return . NoReply

-- | Halt process execution during a call handler, without paying any attention
-- to the expected return type.
haltNoReply :: forall s r . Serializable r => ExitReason -> GenProcess s (ProcessReply r s)
haltNoReply r = stop r >>= noReply

-- | Instructs the process to continue running and receiving messages.
continue :: GenProcess s (ProcessAction s)
continue = processState >>= return . ProcessContinue

-- | Instructs the process loop to wait for incoming messages until 'Delay'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @Delay@ will remain in use until changed.
--
-- Note that @timeoutAfter NoDelay@ will cause the timeout handler to execute
-- immediately if no messages are present in the process' mailbox.
--
timeoutAfter :: Delay -> GenProcess s (ProcessAction s)
timeoutAfter d = processState >>= \s -> return $ ProcessTimeout d s

-- | Instructs the process to /hibernate/ for the given 'TimeInterval'. Note
-- that no messages will be removed from the mailbox until after hibernation has
-- ceased. This is equivalent to calling @threadDelay@.
--
hibernate :: TimeInterval -> GenProcess s (ProcessAction s)
hibernate d = processState >>= \s -> return $ ProcessHibernate d s

-- | The server loop will execute against the supplied 'ProcessDefinition', allowing
-- the process to change its behaviour (in terms of message handlers, exit handling,
-- termination, unhandled message policy, etc)
become :: forall s . ProcessDefinition s -> GenProcess s (ProcessAction s)
become def = processState >>= \st -> return $ ProcessBecome def st

-- | Instructs the process to terminate, giving the supplied reason. If a valid
-- 'shutdownHandler' is installed, it will be called with the 'ExitReason'
-- returned from this call, along with the process state.
stop :: ExitReason -> GenProcess s (ProcessAction s)
stop r = return $ ProcessStop r
