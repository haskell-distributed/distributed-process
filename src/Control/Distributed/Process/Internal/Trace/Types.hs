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
  ( Tracer(..)
  , NodeId
  , ProcessId
  , DiedReason
  , Message
  , SendPort
  , createUnencodedMessage
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
    traceSpawned      :: !(Maybe TraceSubject) -- filter process spawned tracing
  , traceDied         :: !(Maybe TraceSubject) -- filter process died tracing
  , traceRegistered   :: !(Maybe TraceSubject) -- filter process registration tracing
  , traceUnregistered :: !(Maybe TraceSubject) -- filter process un-registration
  , traceSend         :: !(Maybe TraceSubject) -- filter process/message tracing by sender
  , traceRecv         :: !(Maybe TraceSubject) -- filter process/message tracing by receiver
  , traceNodes        :: !Bool                 -- enable node status trace events
  , traceConnections  :: !Bool                 -- enable connection status trace events
  } deriving (Typeable)

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

traceLog :: Tracer -> String -> IO ()
traceLog tr s = traceMessage tr (TraceEvLog s)

traceLogFmt :: Tracer
            -> String
            -> [TraceArg]
            -> IO ()
traceLogFmt t d ls =
  traceLog t $ concat (intersperse d (map toS ls))
  where toS :: TraceArg -> String
        toS (TraceStr s) = s
        toS (Trace    a) = show a

traceEvent :: Tracer -> TraceEvent -> IO ()
traceEvent tr ev = traceIt tr (createUnencodedMessage ev)

traceMessage :: Serializable m => Tracer -> m -> IO ()
traceMessage tr msg = traceEvent tr (TraceEvUser (createUnencodedMessage msg))

enableTrace :: Tracer -> ProcessId -> IO ()
enableTrace t p =
  traceIt t (createUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     (TraceEnable p)))

enableTraceSync :: Tracer -> SendPort TraceOk -> ProcessId -> IO ()
enableTraceSync t s p =
  traceIt t (createUnencodedMessage ((Just s), (TraceEnable p)))

disableTrace :: Tracer -> IO ()
disableTrace t =
  traceIt t (createUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     TraceDisable))

disableTraceSync :: Tracer -> SendPort TraceOk -> IO ()
disableTraceSync t s =
  traceIt t (createUnencodedMessage ((Just s), TraceDisable))

setTraceFlags :: Tracer -> TraceFlags -> IO ()
setTraceFlags t f =
  traceIt t (createUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)), f))

setTraceFlagsSync :: Tracer -> SendPort TraceOk -> TraceFlags -> IO ()
setTraceFlagsSync t s f =
  traceIt t (createUnencodedMessage ((Just s), f))

getTraceFlags :: Tracer -> SendPort TraceFlags -> IO ()
getTraceFlags t s = traceIt t (createUnencodedMessage s)

getCurrentTraceClient :: Tracer -> SendPort (Maybe ProcessId) -> IO ()
getCurrentTraceClient t s = traceIt t (createUnencodedMessage s)

class Traceable a where
  uod :: [a] -> TraceSubject

instance Traceable ProcessId where
  uod = TraceProcs . Set.fromList

instance Traceable String where
  uod = TraceNames . Set.fromList

traceOnly :: Traceable a => [a] -> Maybe TraceSubject
traceOnly = Just . uod

traceOn :: Maybe TraceSubject
traceOn = Just TraceAll

traceOff :: Maybe TraceSubject
traceOff = Nothing

traceIt :: Tracer -> Message -> IO ()
traceIt InactiveTracer         _   = return ()
traceIt (ActiveTracer _ wqRef) msg = do
  mQueue <- deRefWeak wqRef
  forM_ mQueue $ \queue -> enqueue queue msg

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
  put (TraceFlags s d g u m r n c) =
    put s >> put d >> put g >> put u >> put m >> put r >> put n >> put c
  get =
    TraceFlags <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get

instance Binary TraceOk where
  put _ = return ()
  get = return TraceOk

