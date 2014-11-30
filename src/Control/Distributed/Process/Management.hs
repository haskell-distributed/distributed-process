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
-- Some agents may wish to prioritise messages from their mailbox over traffic
-- on the management event bus, or vice versa. The 'mxReceive' and
-- 'mxReceiveChan' API calls do this for the mailbox and event bus,
-- respectively. The /prioritisation/ these APIs offer is simply that the chosen
-- data stream will be checked first. No blocking will occur if the chosen
-- (prioritised) source is devoid of input messages, instead the agent handling
-- code will revert to switching between the alternatives in /round-robin/ as
-- usual. If messages exist in one or more channels, they will be consumed as
-- soon as they're available, priority is effectively a hint about which
-- channel to consume from, should messages be available in both.
--
-- Prioritisation then, is a /hint/ about the preference of data source from
-- which the next input should be chosen. No guarantee can be made that the
-- chosen source will in fact be selected at runtime.
--
-- [Management API Semantics]
--
-- The management API provides /no guarantees whatsoever/, viz:
--
--  * The ordering of messages delivered to the event bus.
--
--  * The order in which agents will be executed.
--
--  * Whether messages will be taken from the mailbox first, or the event bus.
--
-- [Management Data API]
--
-- Both management agents and clients of the API have access to a variety of
-- data storage capabilities, to facilitate publishing and consuming useful
-- system information. Agents maintain their own internal state privately (via a
-- state transformer - see 'mxGetLocal' et al), however it is possible for
-- agents to share additional data with each other (and the outside world)
-- using /data tables/.
--
-- Each agent is assigned its own data table, which acts as a shared map, where
-- the keys are @String@s and the values are @Serializable@ datum of whatever
-- type the agent or its clients stores.
--
-- Because an agent's /data table/ stores its values in raw 'Message' format,
-- it works effectively as an /un-typed dictionary/, into which data of varying
-- types can be fed and later retrieved. The upside of this is that different
-- keys can be mapped to various types without any additional work on the part
-- of the developer. The downside is that the code reading these values must
-- know in advance what type(s) to expect, and the API provides no additional
-- support for handling that.
--
-- Publishing is accomplished using the 'mxPublish' and 'mxSet' APIs, whilst
-- querying and deletion are handled by 'mxGet', 'mxClear', 'mxPurgeTable' and
-- 'mxDropTable' respectively.
--
-- When a management agent terminates, their tables are left in memory despite
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
-- [Example Code]
--
-- What follows is a grossly over-simplified example of a management agent that
-- provides a basic name monitoring facility. Whenever a process name is
-- registered or unregistered, clients are informed of the fact.
--
-- > -- simple notification data type
-- >
-- > data Registration = Reg { added  :: Bool
-- >                         , procId :: ProcessId
-- >                         , name   :: String
-- >                         }
-- >
-- > -- start a /name monitoring agent/
-- > nameMonitorAgent = do
-- >   mxAgent (MxAgentId "name-monitor") Set.empty [
-- >         (mxSink $ \(pid :: ProcessId) -> do
-- >            mxUpdateState $ Set.insert pid
-- >            mxReady)
-- >       , (mxSink $
-- >             let act =
-- >                   case ev of
-- >                     (MxRegistered   p n) -> notify True  n p
-- >                     (MxUnRegistered p n) -> notify False n p
-- >                     _                    -> return ()
-- >             act >> mxReady)
-- >     ]
-- >   where
-- >     notify a n p = do
-- >       Foldable.mapM_ (liftMX . deliver (Reg a n p)) =<< mxGetLocal
-- >
--
-- The client interface (for sending their pid) can take one of two forms:
--
-- > monitorNames = getSelfPid >>= nsend "name-monitor"
-- > monitorNames2 = getSelfPid >>= mxNotify
--
-- For some real-world examples, see the distributed-process-platform package.
--
-- [Performance, Stablity and Scalability]
--
-- /Management Agents/ offer numerous advantages over regular processes:
-- broadcast communication with them can have a lower latency, they offer
-- simplified messgage (i.e., input type) handling and they have access to
-- internal system information that would be otherwise unobtainable.
--
-- Do not be tempted to implement everything (e.g., the kitchen sink) using the
-- management API though. There are overheads associated with management agents
-- which is why they're presented as tools for consuming low level system
-- information, instead of as /application level/ development tools.
--
-- Agents that rely heavily on a busy mailbox can cause the management event
-- bus to backlog un-GC'ed data, leading to increased heap space. Producers that
-- do not take care to avoid passing unevaluated thunks to the API can crash
-- /all/ the agents in the system. Agents are not monitored or managed in any
-- way, and those that crash will not be restarted.
--
-- The management event bus can receive a great deal of traffic. Every time
-- a message is sent and/or received, an event is passed to the agent controller
-- and broadcast to all agents (plus the trace controller, if tracing is enabled
-- for the node). This is already a significant overhead - though profiling and
-- benchmarks have demonstrated that it does not adversely affect performance
-- if few agents are installed. Agents will typically use more cycles than plain
-- processes, since they perform additional work: selecting input data from both
-- the event bus /and/ their own mailboxes, plus searching through the set of
-- event sinks (for each agent) to determine the right handler for the event.
--
-- Each management agent requires not only its own @Process@ (in which the agent
-- code is run), but also a peer process that provides its /data table/. These
-- data tables also have to be coordinated and manaaged on each agent's behalf.
--
-- [Architecture Overview]
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
-- implementation (i.e., /server loop/) is responsible for consuming
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
  ( readTChan
  , writeTChan
  , TChan
  )
import Control.Distributed.Process.Internal.Primitives
  ( newChan
  , nsend
  , receiveWait
  , matchChan
  , matchAny
  , matchSTM
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
import Control.Distributed.Process.Management.Internal.Bus (publishEvent)
import qualified Control.Distributed.Process.Management.Internal.Table as Table
import Control.Distributed.Process.Management.Internal.Types
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
  ( get
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
-- For publishing @Serializable@ data, use 'mxSet' instead.
--
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
    runAgent eh hs cs c s =
      runAgentWithFinalizer eh hs cs c s
        `onException` runAgentFinalizer eh s

    runAgentWithFinalizer :: MxAgent s ()
                          -> [MxSink s]
                          -> ChannelSelector
                          -> TChan Message
                          -> MxAgentState s
                          -> Process ()
    runAgentWithFinalizer eh' hs' cs' c' s' = do
      msg <- getNextInput cs' c'
      (action, state) <- runPipeline msg s' $ pipeline hs'
      case action of
        MxAgentReady               -> runAgent eh' hs' InputChan c' state
        MxAgentPrioritise priority -> runAgent eh' hs' priority  c' state
        MxAgentDeactivate _        -> runAgentFinalizer eh' state
        MxAgentSkip                -> error "IllegalState"
--      MxAgentBecome h'           -> runAgent h' c state

    getNextInput sel chan =
      let matches =
            case sel of
              Mailbox   -> [ matchAny return
                           , matchSTM (readTChan chan) return]
              InputChan -> [ matchSTM (readTChan chan) return
                           , matchAny return]
      in receiveWait matches

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
