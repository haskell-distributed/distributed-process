{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE ImpredicativeTypes        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Execution.EventManager
-- Copyright   :  (c) Well-Typed / Tim Watson
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- [Overview]
--
-- The /EventManager/ is a parallel/concurrent event handling tool, built on
-- top of the /Exchange API/. Arbitrary events are published to the event
-- manager using 'notify', and are broadcast simulataneously to a set of
-- registered /event handlers/.
--
-- [Defining and Registering Event Handlers]
--
-- Event handlers are defined as @Serializable m => s -> m -> Process s@,
-- i.e., an expression taking an initial state, an arbitrary @Serializable@
-- event/message and performing an action in the @Process@ monad that evaluates
-- to a new state.
--
-- See "Control.Distributed.Process.Platform.Execution.Exchange".
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Execution.EventManager
  ( EventManager
  , start
  , startSupervised
  , startSupervisedRef
  , notify
  , addHandler
  , addMessageHandler
  ) where

import Control.Distributed.Process hiding (Message, link)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.Platform.Execution.Exchange
  ( Exchange
  , Message(..)
  , post
  , broadcastExchange
  , broadcastExchangeT
  , broadcastClient
  )
import qualified Control.Distributed.Process.Platform.Execution.Exchange as Exchange
  ( startSupervised
  )
import Control.Distributed.Process.Platform.Internal.Primitives
import Control.Distributed.Process.Platform.Internal.Unsafe
  ( InputStream
  , matchInputStream
  )
import Control.Distributed.Process.Platform.Supervisor (SupervisorPid)
import Control.Distributed.Process.Serializable hiding (SerializableDict)
import Data.Binary
import Data.Typeable (Typeable)
import GHC.Generics

{- notes

Event manager is implemented over a simple BroadcastExchange. We eschew the
complexities of identifying handlers and allowing them to be removed/deleted
or monitored, since we avoid running them in the exchange process. Instead,
each handler runs as an independent process, leaving handler management up
to the user and allowing all the usual process managemnet techniques (e.g.,
registration, supervision, etc) to be utilised instead.

-}

-- | Opaque handle to an Event Manager.
--
newtype EventManager = EventManager { ex :: Exchange }
  deriving (Typeable, Generic)
instance Binary EventManager where

instance Resolvable EventManager where
  resolve = resolve . ex

-- | Start a new /Event Manager/ process and return an opaque handle
-- to it.
start :: Process EventManager
start = broadcastExchange >>= return . EventManager

startSupervised :: SupervisorPid -> Process EventManager
startSupervised sPid = do
  ex <- broadcastExchangeT >>= \t -> Exchange.startSupervised t sPid
  return $ EventManager ex

startSupervisedRef :: SupervisorPid -> Process (ProcessId, P.Message)
startSupervisedRef sPid = do
  ex <- startSupervised sPid
  Just pid <- resolve ex
  return (pid, unsafeWrapMessage ex)

-- | Broadcast an event to all registered handlers.
notify :: Serializable a => EventManager -> a -> Process ()
notify em msg = post (ex em) msg

-- | Add a new event handler. The handler runs in its own process,
-- which is spawned locally on behalf of the caller.
addHandler :: forall s a. Serializable a
           => EventManager
           -> (s -> a -> Process s)
           -> Process s
           -> Process ProcessId
addHandler m h s =
  spawnLocal $ newHandler (ex m) (\s' m' -> handleMessage m' (h s')) s

-- | As 'addHandler', but operates over a raw @Control.Distributed.Process.Message@.
addMessageHandler :: forall s.
                     EventManager
                  -> (s -> P.Message -> Process (Maybe s))
                  -> Process s
                  -> Process ProcessId
addMessageHandler m h s = spawnLocal $ newHandler (ex m) h s

newHandler :: forall s .
              Exchange
           -> (s -> P.Message -> Process (Maybe s))
           -> Process s
           -> Process ()
newHandler ex handler initState = do
  linkTo ex
  is <- broadcastClient ex
  listen is handler =<< initState

listen :: forall s . InputStream Message
       -> (s -> P.Message -> Process (Maybe s))
       -> s
       -> Process ()
listen inStream handler state = do
  receiveWait [ matchInputStream inStream ] >>= handleEvent inStream handler state
  where
    handleEvent is h s p = do
      r <- h s (payload p)
      let s2 = case r of
                 Nothing -> s
                 Just s' -> s'
      listen is h s2

