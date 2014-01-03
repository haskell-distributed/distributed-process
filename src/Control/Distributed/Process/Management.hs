{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
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
    MxEvent(..)
    -- * Firing Arbitrary /Mx Events/
  , mxNotify
    -- * Constructing Mx Agents
  , MxAction()
  , MxAgentId(..)
  , MxAgent()
  , mxAgent
  , mxAgentWithFinalize
  , MxSink
  , mxSink
  , mxGetId
  , mxDeactivate
  , mxReady
  , mxBroadcast
  , mxSetLocal
  , mxGetLocal
  , liftMX
    -- * Mx Data API
  , mxPublish
  , mxSet
  , mxGet
  , mxClear
  , mxPurgeTable
  , mxDropTable
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
  ( tryReadTChan
  , writeTChan
  )
import Control.Distributed.Process.Internal.Primitives
  ( newChan
  , nsend
  , receiveWait
  , receiveTimeout
  , matchChan
  , matchAny
  , unwrapMessage
  , onException
  , register
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
  , MxAction(..)
  , MxAgentState(..)
  , MxAgentStart(..)
  , MxSink
  , MxEvent(..)
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
mxSet mxId key msg = do
  Table.set key (unsafeCreateUnencodedMessage msg) (Table.MxForAgent mxId)

-- | Fetches a property from the management database for the given key.
-- If the property is not set, or does not match the expected type when
-- typechecked (at runtime), returns @Nothing@.
mxGet :: Serializable a => MxAgentId -> String -> Process (Maybe a)
mxGet = Table.fetch . Table.MxForAgent

-- | Clears a property from the management database using the given key.
-- If the key does not exist in the database, this is a noop.
mxClear :: MxAgentId -> String -> Process ()
mxClear mxId key = Table.clear key (Table.MxForAgent mxId)

-- | Purges a table in the management database of all its stored properties.
mxPurgeTable :: MxAgentId -> Process ()
mxPurgeTable = Table.purge . Table.MxForAgent

-- | Deletes a table from the management database.
mxDropTable :: MxAgentId -> Process ()
mxDropTable = Table.delete . Table.MxForAgent

--------------------------------------------------------------------------------
-- API for writing user defined management extensions (i.e., agents)          --
--------------------------------------------------------------------------------

mxGetId :: MxAgent s MxAgentId
mxGetId = ST.get >>= return . mxAgentId

mxBroadcast :: (Serializable m) => m -> MxAgent s ()
mxBroadcast msg = do
  state <- ST.get
  liftMX $ liftIO $ atomically $ do
    writeTChan (mxBus state) (unsafeCreateUnencodedMessage msg)

mxDeactivate :: forall s. String -> MxAgent s MxAction
mxDeactivate = return . MxAgentDeactivate

mxReady :: forall s. MxAgent s MxAction
mxReady = return MxAgentReady

liftMX :: Process a -> MxAgent s a
liftMX p = MxAgent $ ST.lift p

mxSetLocal :: s -> MxAgent s ()
mxSetLocal s = ST.modify $ \st -> st { mxLocalState = s }

mxGetLocal :: MxAgent s s
mxGetLocal = ST.get >>= return . mxLocalState

mxSink :: forall s m . (Serializable m)
       => (m -> MxAgent s MxAction)
       -> MxSink s
mxSink act msg = do
  msg' <- liftMX $ (unwrapMessage msg :: Process (Maybe m))
  case msg' of
    Nothing -> return Nothing
    Just m  -> act m >>= return . Just

data MxPipeline s =
  MxPipeline
  {
    current  :: !(MxSink s)
  , next     :: !(MxPipeline s)
  } | MxStop

-- | Activates a new agent.
--
mxAgent :: MxAgentId -> s -> [MxSink s] -> Process ProcessId
mxAgent mxId st hs = mxAgentWithFinalize mxId st hs $ return ()

-- | Activates a new agent. This variant takes a /finalizer/ expression,
-- that is run once the agent shuts down (even in case of failure/exceptions).
-- The /finalizer/ expression runs in the mx monad -  @MxAgent s ()@ - such
-- that the agent's internal state remains accessible to the shutdown/cleanup
-- code.
--
mxAgentWithFinalize :: MxAgentId
        -> s
        -> [MxSink s]
        -> MxAgent s ()
        -> Process ProcessId
mxAgentWithFinalize mxId initState handlers dtor = do
    node <- processNode <$> ask
    pid <- liftIO $ mxNew (localEventBus node) $ start
    register (agentId mxId) pid
    return pid
  where
    start (sendTChan, recvTChan) = do
      (sp, rp) <- newChan
      nsend Table.mxTableCoordinator (MxAgentStart sp mxId)
      -- liftIO $ putStrLn $ "waiting on table coordinator " ++ Table.mxTableCoordinator
      -- p <- whereis Table.mxTableCoordinator
      -- liftIO $ putStrLn $ "registration == " ++ (show p)
      tablePid <- receiveWait [ matchChan rp (\(p :: ProcessId) -> return p) ]
      -- liftIO $ putStrLn "starting agent listener..."
      runAgent dtor handlers recvTChan $ MxAgentState mxId sendTChan tablePid initState

    runAgent eh hs c s =
      runAgentWithFinalizer eh hs c s `onException` runAgentFinalizer eh s

    runAgentWithFinalizer eh' hs' c' s' = do
          msg <- getNextMessage c'
          (action, state) <- runPipeline msg s' $ pipeline hs'
          case action of
            MxAgentReady        -> runAgent eh' hs' c' state
            MxAgentDeactivate _ -> runAgentFinalizer eh' state
--          MxAgentBecome h'    -> runAgent h' c state

    getNextMessage tch = do
      inputs <- liftIO $ atomically $ tryReadTChan tch
      case inputs of
        Nothing -> do
          m <- receiveTimeout 0 [ matchAny return ]
          case m of
            Nothing  -> getNextMessage tch
            Just msg -> return msg
        Just m  -> return m

    runAgentFinalizer :: MxAgent s () -> MxAgentState s -> Process ()
    runAgentFinalizer f s = ST.runStateT (unAgent f) s >>= return . fst

    pipeline :: forall s . [MxSink s] -> MxPipeline s
    pipeline []           = MxStop
    pipeline (sink:sinks) = MxPipeline sink (pipeline sinks)

    runPipeline :: forall s .
                   Message
                -> MxAgentState s
                -> MxPipeline s
                -> Process (MxAction, MxAgentState s)
    runPipeline _   state MxStop         = return (MxAgentReady, state)
    runPipeline msg state MxPipeline{..} = do
      let act = current msg
      (pass, state') <- ST.runStateT (unAgent act) state
      case pass of
        Nothing     -> runPipeline msg state next
        Just result -> return (result, state')

