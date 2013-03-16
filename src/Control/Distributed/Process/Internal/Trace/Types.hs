-- | Tracing/Debugging support - Types
module Control.Distributed.Process.Internal.Trace.Types
  ( Tracer(..)
  , TraceEvent(..)
  , SetTrace(..)
  , Addressable(..)
  , TraceSubject(..)
  , TraceFlags(..)
  , defaultTraceFlags
  , TraceArg(..)
  , TraceOk(..)
  ) where

import Control.Applicative ((<$>), (<*>))
import Control.Distributed.Process.Internal.Types
  ( Tracer(..)
  , NodeId
  , ProcessId
  , DiedReason
  , Message
  )
import Data.Binary
import Data.Set (Set)
import Data.Typeable
import Network.Transport
  ( ConnectionId
  )

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data SetTrace = TraceEnable !ProcessId | TraceDisable
  deriving (Typeable, Eq, Show)

-- | An event that is fired when something /interesting/ happens.
-- Trace events are forwarded to a trace listener process, of which
-- at most one can be registered per-node.
data TraceEvent =
    TraceEvSpawned        ProcessId
    -- ^ fired whenever a local process is spawned
  | TraceEvRegistered     ProcessId    String
    -- ^ fired whenever a process/name is registered (locally)
  | TraceEvUnRegistered   ProcessId    String
    -- ^ fired whenever a process/name is unregistered (locally)
  | TraceEvDied           ProcessId    DiedReason
    -- ^ fired whenever a process dies
  | TraceEvNodeDied       NodeId       DiedReason
    -- ^ fired whenever a node /dies/ (i.e., the connection is broken/disconnected)
  | TraceEvSent           ProcessId    ProcessId Message
    -- ^ fired whenever a message is sent from a local process
  | TraceEvReceived       ProcessId    Message
    -- ^ fired whenever a message is received by a local process
  | TraceEvConnected      ConnectionId
    -- ^ fired when a network-transport connection is first established
  | TraceEvDisconnected   ConnectionId
    -- ^ fired when a network-transport connection is broken/disconnected
  | TraceEvUser           Message
    -- ^ a user defined trace event (see 'traceMessage')
  | TraceEvLog            String
    -- ^ a /logging/ event - used for debugging purposes only
  | TraceEvTakeover       ProcessId
    -- ^ notifies a trace listener that all subsequent traces will be sent to /pid/
  | TraceEvDisable
    -- ^ notifies a trace listener that it has been disabled/removed
    deriving (Typeable, Show)

class Addressable a where
  resolveToPid :: a -> Maybe ProcessId

instance Addressable TraceEvent where
  resolveToPid (TraceEvSpawned  p)     = Just p
  resolveToPid (TraceEvDied     p _)   = Just p
  resolveToPid (TraceEvSent     _ p _) = Just p
  resolveToPid (TraceEvReceived p _)   = Just p
  resolveToPid _                       = Nothing

-- | Defines which processes will be traced by a given 'TraceFlag',
-- either by name, or @ProcessId@. Choosing @TraceAll@ is /by far/
-- the most efficient approach, as the tracer process therefore
-- avoids deciding whether or not a trace event is viable.
--
data TraceSubject =
    TraceAll                     -- enable tracing for all running processes
  | TraceProcs !(Set ProcessId)  -- enable tracing for a set of processes
  | TraceNames !(Set String)     -- enable tracing for a set of named/registered processes

-- | Defines /what/ will be traced. Flags that control tracing of
-- @Process@ events, take a 'TraceSubject' controlling which processes
-- should generate trace events in the target process.
data TraceFlags = TraceFlags {
    traceSpawned     :: !(Maybe TraceSubject) -- filter process spawned tracing
  , traceDied        :: !(Maybe TraceSubject) -- filter process died tracing
  , traceSend        :: !(Maybe TraceSubject) -- filter process/message tracing by sender
  , traceRecv        :: !(Maybe TraceSubject) -- filter process/message tracing by receiver
  , traceNodes       :: !Bool                 -- enable node status trace events
  , traceConnections :: !Bool                 -- enable connection status trace events
  } deriving (Typeable)

defaultTraceFlags :: TraceFlags
defaultTraceFlags =
  TraceFlags {
    traceSpawned     = Nothing
  , traceDied        = Nothing
  , traceSend        = Nothing
  , traceRecv        = Nothing
  , traceNodes       = False
  , traceConnections = False
  }

data TraceArg =
    TraceStr String
  | forall a. (Show a) => Trace a

-- | A generic 'ok' response from the trace coordinator.
data TraceOk = TraceOk
  deriving (Typeable)

--------------------------------------------------------------------------------
-- Binary Instances                                                           --
--------------------------------------------------------------------------------

instance Binary SetTrace where
  put (TraceEnable pid) = putWord8 1 >> put pid
  put TraceDisable      = putWord8 2

  get = do
    header <- getWord8
    case header of
      1 -> TraceEnable <$> get
      2 -> return TraceDisable
      _ -> error "SetTrace.get - invalid header"

instance Binary TraceEvent where
  put (TraceEvSpawned pid)          = putWord8 1 >> put pid
  put (TraceEvRegistered pid str)   = putWord8 2 >> put pid >> put str
  put (TraceEvUnRegistered pid str) = putWord8 3 >> put pid >> put str
  put (TraceEvDied pid res)         = putWord8 4 >> put pid >> put res
  put (TraceEvNodeDied nid res)     = putWord8 5 >> put nid >> put res
  put (TraceEvSent to from msg)     = putWord8 6 >> put to >> put from >> put msg
  put (TraceEvReceived pid msg)     = putWord8 7 >> put pid >> put msg
  put (TraceEvConnected cid)        = putWord8 8 >> put cid
  put (TraceEvDisconnected cid)     = putWord8 9 >> put cid
  put (TraceEvUser msg)             = putWord8 10 >> put msg
  put (TraceEvLog  msg)             = putWord8 11 >> put msg
  put (TraceEvTakeover pid)         = putWord8 12 >> put pid
  put TraceEvDisable                = putWord8 13

  get = do
    header <- getWord8
    case header of
      1  -> TraceEvSpawned <$> get
      2  -> TraceEvRegistered <$> get <*> get
      3  -> TraceEvUnRegistered <$> get <*> get
      4  -> TraceEvDied <$> get <*> get
      5  -> TraceEvNodeDied <$> get <*> get
      6  -> TraceEvSent <$> get <*> get <*> get
      7  -> TraceEvReceived <$> get <*> get
      8  -> TraceEvConnected <$> get
      9  -> TraceEvDisconnected <$> get
      10 -> TraceEvUser <$> get
      11 -> TraceEvLog <$> get
      12 -> TraceEvTakeover <$> get
      13 -> return TraceEvDisable
      _ -> error "TraceEvent.get - invalid header"

instance Binary TraceSubject where
  put TraceAll           = putWord8 1
  put (TraceProcs pids)  = putWord8 2 >> put pids
  put (TraceNames names) = putWord8 3 >> put names

  get = do
    header <- getWord8
    case header of
      1 -> return TraceAll
      2 -> TraceProcs <$> get
      3 -> TraceNames <$> get
      _ -> error "TraceSubject.get - invalid header"

instance Binary TraceFlags where
  put (TraceFlags s d m r n c) = put s >> put d >> put m >> put r >> put n >> put c
  get = TraceFlags <$> get <*> get <*> get <*> get <*> get <*> get

instance Binary TraceOk where
  put _ = return ()
  get = return TraceOk

