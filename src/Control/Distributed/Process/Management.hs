{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE PatternGuards              #-}
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
-- [Management Extensions API]
--
-- This module presents an API for creating /Management Agents/:
-- special processes that are capable of receiving and responding to
-- a node's internal system events. These /system events/ are delivered by
-- the management event bus: An internal subsystem maintained for each
-- running node, to which all agents are automatically subscribed.
--
-- /Agents/ are defined in terms of /event sinks/, taking a particular
-- @Serializable@ type and evaluating to an action in the 'MxAgent' monad in
-- response. Each 'MxSink' evaluates to an 'MxAction' that specifies whether
-- the agent should continue processing it's inputs or stop. If the type of a
-- message cannot be matched to any of the agent's sinks, it will be discarded.
-- A sink can also deliberately skip processing a message, deferring to the
-- remaining handlers. This is the /only/ way that more than one event sink
-- can handle the same data type, since otherwise the first /type match/ will
-- /win/ every time a message arrives. See 'mxSkip' for details.
--
-- Various events are published to the management event bus automatically,
-- the full list of which can be found in the definition of the 'MxEvent' data
-- type. Additionally, clients of the /Management API/ can publish arbitrary
-- @Serializable@ data to the event bus using 'mxNotify'. All running agents
-- receive all events (from the primary event bus to which they're subscribed).
--
-- Agent processes are automatically registered on the local node, and can
-- receive messages via their mailbox just like ordinary processes. Unlike
-- ordinary @Process@ code however, it is unnecessary (though possible) for
-- agents to use the base @expect@ and @receiveX@ primitives to do this, since
-- the management infrastructure will continuously read from both the primary
-- event bus /and/ the process' own mailbox. Messages are transparently passed
-- to the agent's event sinks from both sources, so an agent need only concern
-- itself with how to respond to its inputs.
--
-- [Management Data API]
--
-- Both management agents and clients of the API have access to a variety of
-- data storage capabilities, to facilitate publishing and consuming information
-- obtained by agents. Each agent is assigned its own data table, which acts
-- as a shared map, where the keys are @String@s and the values are
-- @Serializable@ datum of whatever type the agent or its clients stores.
--
-- Publishing is accomplished using the 'mxPublish' and 'mxSet' APIs, whilst
-- querying and deletion are handled by 'mxGet', 'mxClear', 'mxPurgeTable' and
-- 'mxDropTable' respectively.
--
-- When management agents terminate, their tables are left in memory despite the
-- termination, such that an agent may resume its role (by restarting) or have
-- its 'MxAgentId' taken over by another subsequent agent, leaving the data
-- originally captured in place.
--
-- [Defining Agents]
--
-- New agents are defined with 'mxAgent' and require a unique 'MxAgentId', an
-- initial state - 'MxAgent' runs in a state transformer - and a list of the
-- agent's event sinks. Each 'MxSink' is defined in terms of a specific
-- @Serializable@ type, via the 'mxSink' function, binding the event handler
-- expression to inputs of only that type.
--
-- Apart from modifying its own local state, an agent can execute arbitrary
-- @Process a@ code via lifting (see 'liftMX') and even publish its own messages
-- back to the primary event bus (see 'mxBroadcast').
--
-- Since messages are delivered to agents from both the management event bus and
-- the agent processes mailbox, agents (i.e., event sinks) will generally have
-- no idea as to their origin. An agent can, however, choose to prioritise the
-- choice of input (source) each time one of its event sinks runs. The /standard/
-- way for an event sink to indicate that the agent is ready for its next input
-- is to evaluate 'mxReady'. When this happens, the management infrastructure
-- will obtain data from the event bus and process' mailbox in a round robbin
-- fashion, i.e., one after the other, changing each time.
--
-- [Architecture Overview]
--
-- /Management Extensions/ can be used by infrastructure or application code,
-- to provide access to runtime instrumentation data, expose control planes
-- and/or provide remote access to external clients.
--
-- The management infrastructure is broken down into three components, which
-- roughly correspond to the modules in which they're implemented:
--
-- 1. @Agent@  - registration and definition of /Management Agents/
-- 2. @Table@  - provides an API for publishing /instrumentation data/
-- 3. @Trace@  - provides an API for tracing/debugging capabilities
--
-- The architecture of the management event bus is internal and subject to
-- change without prior notice. The description that follows is provided for
-- informational purposes only.
--
-- When a node initially starts, two special, internal system processes are
-- started to support the management infrastructure. The first, known as the
-- /trace controller/, is responsible for consuming 'MxEvent's and forwarding
-- them to the configured tracer - see "Control.Distributed.Process.Debug" for
-- further details. The second is the /management agent controller/, and is the
-- primary worker process underpinning the management infrastructure. All
-- published management events are routed to this process, which places them
-- onto a system wide /event bus/ and additionally passes them directly to the
-- /trace controller/.
--
-- There are several reasons for segregating the tracing and management control
-- planes in this fashion. Tracing can be enabled or disabled by clients, whilst
-- the management event bus cannot, since in addition to providing
-- runtime instrumentation, its intended use-cases include node monitoring, peer
-- discovery (via topology providing backends) and other essential system
-- services that require knowledge of otherwise hidden system internals. Tracing
-- is also subject to /trace flags/ that limit the specific 'MxEvent's delivered
-- to trace clients - an overhead/complexity not shared by management agents.
-- Finally, tracing and management agents are implemented using completely
-- different signalling techniques - more on this later - which would introduce
-- considerable complexity if the shared the same /event loop/.
--
-- The management control plane is driven by a shared broadcast channel, which
-- is written to by the agent controller and subscribed to by all agent
-- processes. Agents are spawned as regular processes, whose primary
-- implementation (i.e., their "server loop") is responsible for consuming
-- messages from both the broadcast channel and their own mailbox. Once
-- consumed, messages are applied to the agent's /event sinks/ until one
-- matches the input, at which point it is applied and the loop continues.
-- The implementation chooses from the event bus and the mailbox in a
-- round-robin fashion, until a message is received. This polling activity would
-- lead to management agents consuming considerable system resources if left
-- unchecked, therefore the implementation will poll for a limitted number of
-- retries, after which it will perform a blocking read on the event bus.
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
  , MxSink()
  , mxSink
  , mxGetId
  , mxDeactivate
  , mxReady
  , mxSkip
  , mxReceive
  , mxReceiveChan
  , mxBroadcast
  , mxSetLocal
  , mxGetLocal
  , mxUpdateLocal
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
  , readTChan
  , writeTChan
  , TChan
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
  , whereis
  , die
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
  , ChannelSelector(..)
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

-- | Return the 'MxAgentId' for the currently executing agent.
--
mxGetId :: MxAgent s MxAgentId
mxGetId = ST.get >>= return . mxAgentId

-- | The 'MxAgent' version of 'mxNotify'.
--
mxBroadcast :: (Serializable m) => m -> MxAgent s ()
mxBroadcast msg = do
  state <- ST.get
  liftMX $ liftIO $ atomically $ do
    writeTChan (mxBus state) (unsafeCreateUnencodedMessage msg)

-- | Gracefully terminate an agent.
--
mxDeactivate :: forall s. String -> MxAgent s MxAction
mxDeactivate = return . MxAgentDeactivate

-- | Continue executing (i.e., receiving and processing messages).
--
mxReady :: forall s. MxAgent s MxAction
mxReady = return MxAgentReady

-- | Causes the currently executing /event sink/ to be skipped.
-- The remaining declared event sinks will be evaluated to find
-- a matching handler. Can be used to allow multiple event sinks
-- to process data of the same type.
--
mxSkip :: forall s. MxAgent s MxAction
mxSkip = return MxAgentSkip

-- | Continue exeucting, prioritising inputs from the process' own
-- /mailbox/ ahead of data from the management event bus.
--
mxReceive :: forall s. MxAgent s MxAction
mxReceive = return $ MxAgentPrioritise Mailbox

-- | Continue exeucting, prioritising inputs from the management event bus
-- over the process' own /mailbox/.
--
mxReceiveChan :: forall s. MxAgent s MxAction
mxReceiveChan = return $ MxAgentPrioritise InputChan

-- | Lift a @Process@ action.
--
liftMX :: Process a -> MxAgent s a
liftMX p = MxAgent $ ST.lift p

-- | Set the agent's local state.
--
mxSetLocal :: s -> MxAgent s ()
mxSetLocal s = ST.modify $ \st -> st { mxLocalState = s }

-- | Update the agent's local state.
--
mxUpdateLocal :: (s -> s) -> MxAgent s ()
mxUpdateLocal f = ST.modify $ \st -> st { mxLocalState = (f $ mxLocalState st) }

-- | Fetch the agent's local state.
--
mxGetLocal :: MxAgent s s
mxGetLocal = ST.get >>= return . mxLocalState

-- | Create an 'MxSink' from an expression taking a @Serializable@ type @m@,
-- that yields an 'MxAction' in the 'MxAgent' monad.
--
mxSink :: forall s m . (Serializable m)
       => (m -> MxAgent s MxAction)
       -> MxSink s
mxSink act msg = do
  msg' <- liftMX $ (unwrapMessage msg :: Process (Maybe m))
  case msg' of
    Nothing -> return Nothing
    Just m  -> do
      r <- act m
      case r of
        MxAgentSkip -> return Nothing
        _           -> return $ Just r

-- private ADT: a linked list of event sinks
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
    let name = agentId mxId
    existing <- whereis name
    case existing of
      Just _  -> die "DuplicateAgentId"  -- TODO: better error handling policy
      Nothing -> do
        node <- processNode <$> ask
        pid <- liftIO $ mxNew (localEventBus node) $ start
        register name pid
        return pid
  where
    start (sendTChan, recvTChan) = do
      (sp, rp) <- newChan
      nsend Table.mxTableCoordinator (MxAgentStart sp mxId)
      tablePid <- receiveWait [ matchChan rp (\(p :: ProcessId) -> return p) ]
      let nState = MxAgentState mxId sendTChan tablePid initState
      runAgent dtor handlers InputChan recvTChan nState

    runAgent :: MxAgent s ()
             -> [MxSink s]
             -> ChannelSelector
             -> TChan Message
             -> MxAgentState s
             -> Process ()
    runAgent eh hs r c s =
      runAgentWithFinalizer eh hs r c s
        `onException` runAgentFinalizer eh s

    runAgentWithFinalizer :: MxAgent s ()
                          -> [MxSink s]
                          -> ChannelSelector
                          -> TChan Message
                          -> MxAgentState s
                          -> Process ()
    runAgentWithFinalizer eh' hs' cs' c' s' = do
      (msg, selector') <- getNextInput cs' c'
      (action, state) <- runPipeline msg s' $ pipeline hs'
      case action of
        MxAgentReady               -> runAgent eh' hs' selector' c' state
        MxAgentPrioritise priority -> runAgent eh' hs' priority  c' state
        MxAgentDeactivate _        -> runAgentFinalizer eh' state
        MxAgentSkip                -> error "IllegalState"
--      MxAgentBecome h'           -> runAgent h' c state

    getNextInput sel chan = getNextInput' sel chan (10 :: Int)

    -- when reading inputs, we generally want to maintain a degree of
    -- fairness in choosing between the TChan and our mailbox, but to
    -- ultimately favour the TChan overall. We do this by flipping
    -- between the two (using the ChannelSelector) each time we call
    -- getNextInput - it returns the opposite ChannelSelector to the
    -- one which succeeded last time it was called.
    --
    -- This strategy works well, yet we wish to avoid blocking on one
    -- input if the other is empty/busy, so we begin by reading both
    -- sources conditionally - tryReadTChan for the event bus and
    -- receiveTimeout for the mailbox. If polling (either source) does
    -- not yield an input, we swap to the other, but we cannot continue
    -- in this fashion ad infinitum, since that would waste considerable
    -- system resoures. Instead, we switch ten times, after which (if no
    -- data were obtained) we block on the event bus, since that is our
    -- main priority.
    --
    -- An agent can of course, choose to override which source should be
    -- checked first. We consider this a /hint/ rather than a dictat.
    -- When reading from the mailbox, we perform a non-blocking read.
    -- We assume that most agents will prefer using mxReceiveChan to its
    -- mailbox reading counterpart, this we expect the event bus to be
    -- non-empty or the entire subsystem is likely doing very little work,
    -- in which case we needn't worry too much about the overheads
    -- described thus far.

    getNextInput' InputChan c' 0 = do
      m <- liftIO $ atomically $ readTChan c'
      return (m, Mailbox)
    getNextInput' InputChan c' n = do
      inputs <- liftIO $ atomically $ tryReadTChan c'
      case inputs of
        Nothing -> getNextInput' Mailbox c' (n - 1)
        Just m  -> return (m, Mailbox)
    getNextInput' Mailbox   c' n = do
      m <- receiveTimeout 0 [ matchAny return ]
      case m of
        Nothing  -> getNextInput' InputChan c' (n - 1)
        Just msg -> return (msg, InputChan)

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

