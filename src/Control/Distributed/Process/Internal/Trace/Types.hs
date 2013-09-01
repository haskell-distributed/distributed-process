-- | Tracing/Debugging support - Types
module Control.Distributed.Process.Internal.Trace.Types
  ( MxEventBus(..)
  , MxEvent(..)
  , SetTrace(..)
  , Addressable(..)
  , TraceSubject(..)
  , TraceFlags(..)
  , TraceArg(..)
  , TraceOk(..)
  , traceLog
  , traceLogFmt
  , traceEvent
  , traceMessage
  , defaultTraceFlags
  , enableTrace
  , enableTraceSync
  , disableTrace
  , disableTraceSync
  , getTraceFlags
  , setTraceFlags
  , setTraceFlagsSync
  , getCurrentTraceClient
  ) where

import Control.Applicative ((<$>), (<*>))
import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal.Types
  ( MxEventBus(..)
  , NodeId
  , ProcessId
  , DiedReason
  , Message
  , SendPort
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Management.Bus
  ( publishEvent
  )
import Control.Distributed.Process.Serializable
import Data.Binary
import Data.Foldable (forM_)
import Data.List (intersperse)
import Data.Set (Set)
import qualified Data.Set as Set (fromList)
import Data.Typeable
import System.Mem.Weak (deRefWeak)
import Network.Transport
  ( ConnectionId
  , EndPointAddress
  )

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data SetTrace = TraceEnable !ProcessId | TraceDisable
  deriving (Typeable, Eq, Show)

-- TODO: MOVE the whole Trace namespace into C.D.Process.Management

-- | An event that is fired when something /interesting/ happens.
-- Trace events are forwarded to a trace listener process, of which
-- at most one can be registered per-node.
data MxEvent =
    MxSpawned          ProcessId
    -- ^ fired whenever a local process is spawned
  | MxRegistered       ProcessId    String
    -- ^ fired whenever a process/name is registered (locally)
  | MxUnRegistered     ProcessId    String
    -- ^ fired whenever a process/name is unregistered (locally)
  | MxProcessDied      ProcessId    DiedReason
    -- ^ fired whenever a process dies
  | MxNodeDied         NodeId       DiedReason
    -- ^ fired whenever a node /dies/ (i.e., the connection is broken/disconnected)
  | MxSent             ProcessId    ProcessId Message
    -- ^ fired whenever a message is sent from a local process
  | MxReceived         ProcessId    Message
    -- ^ fired whenever a message is received by a local process
  | MxConnected        ConnectionId EndPointAddress
    -- ^ fired when a network-transport connection is first established
  | MxDisconnected     ConnectionId EndPointAddress
    -- ^ fired when a network-transport connection is broken/disconnected
  | MxUser             Message
    -- ^ a user defined trace event (see 'traceMessage')
  | MxLog              String
    -- ^ a /logging/ event - used for debugging purposes only
  | MxTraceTakeover    ProcessId
    -- ^ notifies a trace listener that all subsequent traces will be sent to /pid/
  | MxTraceDisable
    -- ^ notifies a trace listener that it has been disabled/removed
    deriving (Typeable, Show)

class Addressable a where
  resolveToPid :: a -> Maybe ProcessId

instance Addressable MxEvent where
  resolveToPid (MxSpawned     p)     = Just p
  resolveToPid (MxProcessDied p _)   = Just p
  resolveToPid (MxSent        _ p _) = Just p
  resolveToPid (MxReceived    p _)   = Just p
  resolveToPid _                     = Nothing

-- | Defines which processes will be traced by a given 'TraceFlag',
-- either by name, or @ProcessId@. Choosing @TraceAll@ is /by far/
-- the most efficient approach, as the tracer process therefore
-- avoids deciding whether or not a trace event is viable.
--
data TraceSubject =
    TraceAll                     -- enable tracing for all running processes
  | TraceProcs !(Set ProcessId)  -- enable tracing for a set of processes
  | TraceNames !(Set String)     -- enable tracing for a set of named/registered processes
  deriving (Show)

-- | Defines /what/ will be traced. Flags that control tracing of
-- @Process@ events, take a 'TraceSubject' controlling which processes
-- should generate trace events in the target process.
data TraceFlags = TraceFlags {
    traceSpawned      :: !(Maybe TraceSubject) -- filter process spawned tracing
  , traceDied         :: !(Maybe TraceSubject) -- filter process died tracing
  , traceRegistered   :: !(Maybe TraceSubject) -- filter process registration tracing
  , traceUnregistered :: !(Maybe TraceSubject) -- filter process un-registration
  , traceSend         :: !(Maybe TraceSubject) -- filter process/message tracing by sender
  , traceRecv         :: !(Maybe TraceSubject) -- filter process/message tracing by receiver
  , traceNodes        :: !Bool                 -- enable node status trace events
  , traceConnections  :: !Bool                 -- enable connection status trace events
  } deriving (Typeable, Show)

defaultTraceFlags :: TraceFlags
defaultTraceFlags =
  TraceFlags {
    traceSpawned      = Nothing
  , traceDied         = Nothing
  , traceRegistered   = Nothing
  , traceUnregistered = Nothing
  , traceSend         = Nothing
  , traceRecv         = Nothing
  , traceNodes        = False
  , traceConnections  = False
  }

data TraceArg =
    TraceStr String
  | forall a. (Show a) => Trace a

-- | A generic 'ok' response from the trace coordinator.
data TraceOk = TraceOk
  deriving (Typeable)

--------------------------------------------------------------------------------
-- Internal/Common API                                                        --
--------------------------------------------------------------------------------

traceLog :: MxEventBus -> String -> IO ()
traceLog tr s = publishEvent tr (unsafeCreateUnencodedMessage $ MxLog s)

traceLogFmt :: MxEventBus
            -> String
            -> [TraceArg]
            -> IO ()
traceLogFmt t d ls =
  traceLog t $ concat (intersperse d (map toS ls))
  where toS :: TraceArg -> String
        toS (TraceStr s) = s
        toS (Trace    a) = show a

traceEvent :: MxEventBus -> MxEvent -> IO ()
traceEvent tr ev = publishEvent tr (unsafeCreateUnencodedMessage ev)

traceMessage :: Serializable m => MxEventBus -> m -> IO ()
traceMessage tr msg = traceEvent tr (MxUser (unsafeCreateUnencodedMessage msg))

enableTrace :: MxEventBus -> ProcessId -> IO ()
enableTrace t p =
  publishEvent t (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                                (TraceEnable p)))

enableTraceSync :: MxEventBus -> SendPort TraceOk -> ProcessId -> IO ()
enableTraceSync t s p =
  publishEvent t (unsafeCreateUnencodedMessage (Just s, TraceEnable p))

disableTrace :: MxEventBus -> IO ()
disableTrace t =
  publishEvent t (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     TraceDisable))

disableTraceSync :: MxEventBus -> SendPort TraceOk -> IO ()
disableTraceSync t s =
  publishEvent t (unsafeCreateUnencodedMessage ((Just s), TraceDisable))

setTraceFlags :: MxEventBus -> TraceFlags -> IO ()
setTraceFlags t f =
  publishEvent t (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)), f))

setTraceFlagsSync :: MxEventBus -> SendPort TraceOk -> TraceFlags -> IO ()
setTraceFlagsSync t s f =
  publishEvent t (unsafeCreateUnencodedMessage ((Just s), f))

getTraceFlags :: MxEventBus -> SendPort TraceFlags -> IO ()
getTraceFlags t s = publishEvent t (unsafeCreateUnencodedMessage s)

getCurrentTraceClient :: MxEventBus -> SendPort (Maybe ProcessId) -> IO ()
getCurrentTraceClient t s = publishEvent t (unsafeCreateUnencodedMessage s)

class Traceable a where
  uod :: [a] -> TraceSubject

instance Traceable ProcessId where
  uod = TraceProcs . Set.fromList

instance Traceable String where
  uod = TraceNames . Set.fromList

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

instance Binary MxEvent where
  put (MxSpawned pid)           = putWord8 1 >> put pid
  put (MxRegistered pid str)    = putWord8 2 >> put pid >> put str
  put (MxUnRegistered pid str)  = putWord8 3 >> put pid >> put str
  put (MxProcessDied pid res)   = putWord8 4 >> put pid >> put res
  put (MxNodeDied nid res)      = putWord8 5 >> put nid >> put res
  put (MxSent to from msg)      = putWord8 6 >> put to >> put from >> put msg
  put (MxReceived pid msg)      = putWord8 7 >> put pid >> put msg
  put (MxConnected cid epid)    = putWord8 8 >> put cid >> put epid
  put (MxDisconnected cid epid) = putWord8 9 >> put cid >> put epid
  put (MxUser msg)              = putWord8 10 >> put msg
  put (MxLog  msg)              = putWord8 11 >> put msg
  put (MxTraceTakeover pid)     = putWord8 12 >> put pid
  put MxTraceDisable            = putWord8 13

  get = do
    header <- getWord8
    case header of
      1  -> MxSpawned <$> get
      2  -> MxRegistered <$> get <*> get
      3  -> MxUnRegistered <$> get <*> get
      4  -> MxProcessDied <$> get <*> get
      5  -> MxNodeDied <$> get <*> get
      6  -> MxSent <$> get <*> get <*> get
      7  -> MxReceived <$> get <*> get
      8  -> MxConnected <$> get <*> get
      9  -> MxDisconnected <$> get <*> get
      10 -> MxUser <$> get
      11 -> MxLog <$> get
      12 -> MxTraceTakeover <$> get
      13 -> return MxTraceDisable
      _ -> error "MxEvent.get - invalid header"

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
  put (TraceFlags s d g u m r n c) =
    put s >> put d >> put g >> put u >> put m >> put r >> put n >> put c
  get =
    TraceFlags <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get

instance Binary TraceOk where
  put _ = return ()
  get = return TraceOk

