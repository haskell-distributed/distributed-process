{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Management
-- Copyright   :  (c) Well-Typed / Tim Watson
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- /Management Extensions/ for Cloud Haskell.
--
-- This module provides a standard API for receiving and/or responding to
-- system events in a Cloud Haskell node.
--
-- [Architecture Overview]
--
-- /Management Extensions/ can be used by infrastructure or application code
-- to provide access to runtime instrumentation data, expose control planes
-- and/or provide remote access to external clients.
--
-- The management infrastructure is broken down into three components, which
-- roughly correspond to the modules it exposes:
--
-- 1. @Agent@ - registration and management of /Management Agents/
-- 2. @Instrumentation@ - provides an API for publishing /instrumentation data/
-- 3. @Remote@ - provides an API for remote management and administration
--
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Management
  (
    MxAction()
  , MxAgentId
    -- * Firing /mx events/
  , mxNotify
    -- * Constructing Agents
  , mxAgent
  , mxAgentDeactivate
  , mxAgentReady
  , mxAgentPublish
  , mxSetLocal
  , mxGetLocal
    -- * Lifting
  , liftP
    -- * Management Data API
  , mxPublish
  , mxSet
  , mxGet
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
  ( readTChan
  )
import Control.Distributed.Process.Internal.Primitives
  ( newChan
  , nsend
  , receiveWait
  , matchChan
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , Message
  , LocalProcess(..)
  , LocalNode(..)
  , MxEventBus(..)
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Management.Bus (publishEvent)
import qualified Control.Distributed.Process.Management.Table as Table
import Control.Distributed.Process.Management.Types
  ( MxAgentId(..)
  , MxAgent(..)
  , MxAgentState(..)
  , MxAgentStart(..)
  )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import qualified Control.Monad.State as ST
  ( MonadState
  , StateT
  , get
  , modify
  , lift
  , runStateT
  )

data MxAction =
    MxAgentDeactivate !String
  | MxAgentReady

-- | Publishes an arbitrary @Serializable@ message to the management event bus.
-- Note that /no attempt is made to force the argument/, therefore it is very
-- important that you do not pass unevaluated thunks that might crash the
-- receiving process via this API, since /all/ registered agents will gain
-- access to the data structure once it is broadcast by the agent controller.
mxNotify :: (Serializable a) => a -> Process ()
mxNotify msg = do
  bus <- localEventBus . processNode <$> ask
  liftIO $ publishEvent bus $ unsafeCreateUnencodedMessage msg

-- | Publish an arbitrary @Message@ as a property in the management database.
--
-- For publishing @Serializable@ data, use 'mxSet' instead. For publishing
-- properties efficiently within an agent, use 'mxAgentPublish' instead,
-- since it will be more efficient in that context.
mxPublish :: MxAgentId -> String -> Message -> Process ()
mxPublish a k v = Table.set k v (Table.MxForAgent a)

-- | Sets an arbitrary @Serializable@ datum against a key in the management
-- database. Note that /no attempt is made to force the argument/, therefore
-- it is very important that you do not pass unevaluated thunks that might
-- crash some other, arbitrary process (or management agent!) that obtains
-- and attempts to force the value later on.
--
mxSet :: Serializable a => MxAgentId -> String -> a -> Process ()
mxSet mxId key msg =
  Table.set key (unsafeCreateUnencodedMessage msg) (Table.MxForAgent mxId)

-- | Fetches a property from the management database for the given key.
-- If the property is not set, or does not match the expected type when
-- typechecked (at runtime), returns @Nothing@.
mxGet :: Serializable a => MxAgentId -> String -> Process (Maybe a)
mxGet mxId = Table.fetch (Table.MxForAgent mxId)

--------------------------------------------------------------------------------
-- API for writing user defined management extensions (i.e., agents)          --
--------------------------------------------------------------------------------

mxAgentPublish = undefined

mxAgentDeactivate :: forall s. String -> MxAgent s MxAction
mxAgentDeactivate = return . MxAgentDeactivate

mxAgentReady :: forall s. MxAgent s MxAction
mxAgentReady = return MxAgentReady

liftP :: Process a -> MxAgent s a
liftP p = MxAgent $ ST.lift p

mxSetLocal :: s -> MxAgent s ()
mxSetLocal s = ST.modify $ \st -> st { mxLocalState = s }

mxGetLocal :: MxAgent s s
mxGetLocal = ST.get >>= return . mxLocalState

-- | Activates a new agent.
--
mxAgent :: MxAgentId
        -> s
        -> (Message -> MxAgent s MxAction)
        -> Process ProcessId
mxAgent mxId initState handler = do
    node <- processNode <$> ask
    pid <- liftIO $ mxNew (localEventBus node) $ start
    return pid
  where
    start chan = do
      (sp, rp) <- newChan
      nsend Table.mxTableCoordinator (MxAgentStart sp mxId)
      tablePid <- receiveWait [ matchChan rp (\(p :: ProcessId) -> return p) ]
      runAgent handler chan $ MxAgentState mxId tablePid initState

    runAgent h c s = do
      msg <- (liftIO $ atomically $ readTChan c)
      (action, state) <- runAgentST s $ h msg
      case action of
        MxAgentReady        -> runAgent h c state
        MxAgentDeactivate _ -> {- TODO: log r -} return ()
--        MxAgentBecome h'    -> runAgent h' c state

    runAgentST :: MxAgentState s
               -> MxAgent s MxAction
               -> Process (MxAction, MxAgentState s)
    runAgentST state proc = ST.runStateT (unAgent proc) state

