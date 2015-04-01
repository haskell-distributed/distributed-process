{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE GADTs  #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CPP #-}

-- | Types used throughout the Cloud Haskell framework
--
-- We collect all types used internally in a single module because
-- many of these data types are mutually recursive and cannot be split across
-- modules.
module Control.Distributed.Process.Internal.Types
  ( -- * Node and process identifiers
    NodeId(..)
  , LocalProcessId(..)
  , ProcessId(..)
  , Identifier(..)
  , nodeOf
  , firstNonReservedProcessId
  , nullProcessId
    -- * Local nodes and processes
  , LocalNode(..)
  , Tracer(..)
  , MxEventBus(..)
  , LocalNodeState(..)
  , LocalProcess(..)
  , LocalProcessState(..)
  , Process(..)
  , runLocalProcess
  , ImplicitReconnect(..)
    -- * Typed channels
  , LocalSendPortId
  , SendPortId(..)
  , TypedChannel(..)
  , SendPort(..)
  , ReceivePort(..)
    -- * Messages
  , Message(..)
  , isEncoded
  , createMessage
  , createUnencodedMessage
  , unsafeCreateUnencodedMessage
  , messageToPayload
  , payloadToMessage
    -- * Node controller user-visible data types
  , MonitorRef(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , ProcessExitException(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , ProcessRegistrationException(..)
  , DiedReason(..)
  , DidUnmonitor(..)
  , DidUnlinkProcess(..)
  , DidUnlinkNode(..)
  , DidUnlinkPort(..)
  , SpawnRef(..)
  , DidSpawn(..)
  , WhereIsReply(..)
  , RegisterReply(..)
  , ProcessInfo(..)
  , ProcessInfoNone(..)
  , NodeStats(..)
    -- * Node controller internal data types
  , NCMsg(..)
  , ProcessSignal(..)
    -- * Accessors
  , localProcesses
  , localPidCounter
  , localPidUnique
  , localConnections
  , localProcessWithId
  , localConnectionBetween
  , monitorCounter
  , spawnCounter
  , channelCounter
  , typedChannels
  , typedChannelWithId
    -- * Utilities
  , forever'
  ) where

import System.Mem.Weak (Weak)
import Data.Map (Map)
import Data.Int (Int32)
import Data.Data (Data)
import Data.Typeable (Typeable, typeOf)
import Data.Binary (Binary(put, get), putWord8, getWord8, encode)
import qualified Data.ByteString as BSS (ByteString, concat, copy)
import qualified Data.ByteString.Lazy as BSL
  ( ByteString
  , toChunks
  , splitAt
  , fromChunks
  , length
  )
import qualified Data.ByteString.Lazy.Internal as BSL (ByteString(..))
import Data.Accessor (Accessor, accessor)
import Control.Category ((>>>))
import Control.DeepSeq (NFData(..))
import Control.Exception (Exception)
import Control.Concurrent (ThreadId)
import Control.Concurrent.Chan (Chan)
import Control.Concurrent.STM (STM)
import Control.Concurrent.STM.TChan (TChan)
import qualified Network.Transport as NT (EndPoint, EndPointAddress, Connection)
import Control.Applicative (Applicative, Alternative, (<$>), (<*>))
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Monad.IO.Class (MonadIO)
import Control.Distributed.Process.Serializable
  ( Fingerprint
  , Serializable
  , fingerprint
  , encodeFingerprint
  , sizeOfFingerprint
  , decodeFingerprint
  , showFingerprint
  )
import Control.Distributed.Process.Internal.CQueue (CQueue)
import Control.Distributed.Process.Internal.StrictMVar (StrictMVar)
import Control.Distributed.Process.Internal.WeakTQueue (TQueue)
import Control.Distributed.Static (RemoteTable, Closure)
import qualified Control.Distributed.Process.Internal.StrictContainerAccessors as DAC (mapMaybe)

import Data.Hashable
import GHC.Generics

--------------------------------------------------------------------------------
-- Node and process identifiers                                               --
--------------------------------------------------------------------------------

-- | Node identifier
newtype NodeId = NodeId { nodeAddress :: NT.EndPointAddress }
  deriving (Eq, Ord, Typeable, Data, Generic)
instance Binary NodeId where
instance NFData NodeId where rnf (NodeId a) = rnf a `seq` ()
instance Hashable NodeId where
instance Show NodeId where
  show (NodeId addr) = "nid://" ++ show addr

-- | A local process ID consists of a seed which distinguishes processes from
-- different instances of the same local node and a counter
data LocalProcessId = LocalProcessId
  { lpidUnique  :: {-# UNPACK #-} !Int32
  , lpidCounter :: {-# UNPACK #-} !Int32
  }
  deriving (Eq, Ord, Typeable, Data, Generic, Show)

instance Hashable LocalProcessId where

-- | Process identifier
data ProcessId = ProcessId
  { -- | The ID of the node the process is running on
    processNodeId  :: !NodeId
    -- | Node-local identifier for the process
  , processLocalId :: {-# UNPACK #-} !LocalProcessId
  }
  deriving (Eq, Ord, Typeable, Data, Generic)

instance Binary ProcessId where
instance NFData ProcessId where rnf (ProcessId n _) = rnf n `seq` ()
instance Hashable ProcessId where

instance Show ProcessId where
  show (ProcessId (NodeId addr) (LocalProcessId _ lid))
    = "pid://" ++ show addr ++ ":" ++ show lid

-- | Union of all kinds of identifiers
data Identifier =
    NodeIdentifier !NodeId
  | ProcessIdentifier !ProcessId
  | SendPortIdentifier !SendPortId
  deriving (Eq, Ord, Generic)

instance Hashable Identifier where
instance NFData Identifier where
  rnf (NodeIdentifier n) = rnf n `seq` ()
  rnf (ProcessIdentifier n) = rnf n `seq` ()
  rnf n@SendPortIdentifier{} = n `seq` ()

instance Show Identifier where
  show (NodeIdentifier nid)     = show nid
  show (ProcessIdentifier pid)  = show pid
  show (SendPortIdentifier cid) = show cid

nodeOf :: Identifier -> NodeId
nodeOf (NodeIdentifier nid)     = nid
nodeOf (ProcessIdentifier pid)  = processNodeId pid
nodeOf (SendPortIdentifier cid) = processNodeId (sendPortProcessId cid)

--------------------------------------------------------------------------------
-- Special PIDs                                                               --
--------------------------------------------------------------------------------

firstNonReservedProcessId :: Int32
firstNonReservedProcessId = 1

nullProcessId :: NodeId -> ProcessId
nullProcessId nid =
  ProcessId { processNodeId  = nid
            , processLocalId = LocalProcessId { lpidUnique  = 0
                                              , lpidCounter = 0
                                              }
            }

--------------------------------------------------------------------------------
-- Local nodes and processes                                                  --
--------------------------------------------------------------------------------

-- | Provides access to the trace controller
data Tracer = Tracer
              {
                -- | Process id for the currently active trace handler
                tracerPid :: !ProcessId
                -- | Weak reference to the tracer controller's mailbox
              , weakQ     :: !(Weak (CQueue Message))
              }

-- | Local system management event bus state
data MxEventBus =
    MxEventBusInitialising
  | MxEventBus
    {
      -- | Process id of the management agent controller process
      agent  :: !ProcessId
      -- | Configuration for the local trace controller
    , tracer :: !Tracer
      -- | Weak reference to the management agent controller's mailbox
    , evbuss :: !(Weak (CQueue Message))
      -- | API for adding management agents to a running node
    , mxNew  :: !(((TChan Message, TChan Message) -> Process ()) -> IO ProcessId)
--    , mxReg  :: !(StrictMVar (Map MxAgentId ))
    }

-- | Local nodes
data LocalNode = LocalNode
  { -- | 'NodeId' of the node
    localNodeId     :: !NodeId
    -- | The network endpoint associated with this node
  , localEndPoint   :: !NT.EndPoint
    -- | Local node state
  , localState      :: !(StrictMVar LocalNodeState)
    -- | Channel for the node controller
  , localCtrlChan   :: !(Chan NCMsg)
    -- | Internal management event bus
  , localEventBus   :: !MxEventBus
    -- | Runtime lookup table for supporting closures
    -- TODO: this should be part of the CH state, not the local endpoint state
  , remoteTable     :: !RemoteTable
  }

data ImplicitReconnect = WithImplicitReconnect | NoImplicitReconnect
  deriving (Eq, Show)

-- | Local node state
data LocalNodeState = LocalNodeState
  { -- | Processes running on this node
    _localProcesses   :: !(Map LocalProcessId LocalProcess)
    -- | Counter to assign PIDs
  , _localPidCounter  :: !Int32
    -- | The 'unique' value used to create PIDs (so that processes on
    -- restarted nodes have new PIDs)
  , _localPidUnique   :: !Int32
    -- | Outgoing connections
  , _localConnections :: !(Map (Identifier, Identifier)
                               (NT.Connection, ImplicitReconnect))
  }

-- | Processes running on our local node
data LocalProcess = LocalProcess
  { processQueue  :: !(CQueue Message)
  , processWeakQ  :: !(Weak (CQueue Message))
  , processId     :: !ProcessId
  , processState  :: !(StrictMVar LocalProcessState)
  , processThread :: !ThreadId
  , processNode   :: !LocalNode
  }

-- | Deconstructor for 'Process' (not exported to the public API)
runLocalProcess :: LocalProcess -> Process a -> IO a
runLocalProcess lproc proc = runReaderT (unProcess proc) lproc

-- | Local process state
data LocalProcessState = LocalProcessState
  { _monitorCounter :: !Int32
  , _spawnCounter   :: !Int32
  , _channelCounter :: !Int32
  , _typedChannels  :: !(Map LocalSendPortId TypedChannel)
  }

-- | The Cloud Haskell 'Process' type
newtype Process a = Process {
    unProcess :: ReaderT LocalProcess IO a
  }
  deriving (Functor, Monad, MonadIO, MonadReader LocalProcess, Typeable, Applicative)

--------------------------------------------------------------------------------
-- Typed channels                                                             --
--------------------------------------------------------------------------------

type LocalSendPortId = Int32

-- | A send port is identified by a SendPortId.
--
-- You cannot send directly to a SendPortId; instead, use 'newChan'
-- to create a SendPort.
data SendPortId = SendPortId {
    -- | The ID of the process that will receive messages sent on this port
    sendPortProcessId :: {-# UNPACK #-} !ProcessId
    -- | Process-local ID of the channel
  , sendPortLocalId   :: {-# UNPACK #-} !LocalSendPortId
  }
  deriving (Eq, Ord, Typeable, Generic)

instance Hashable SendPortId where
instance Show SendPortId where
  show (SendPortId (ProcessId (NodeId addr) (LocalProcessId _ plid)) clid)
    = "cid://" ++ show addr ++ ":" ++ show plid ++ ":" ++ show clid

instance NFData SendPortId where
  rnf (SendPortId p _) = rnf p `seq` ()

data TypedChannel = forall a. Serializable a => TypedChannel (Weak (TQueue a))

-- | The send send of a typed channel (serializable)
newtype SendPort a = SendPort {
    -- | The (unique) ID of this send port
    sendPortId :: SendPortId
  }
  deriving (Typeable, Generic, Show, Eq, Ord)

instance (Serializable a) => Binary (SendPort a) where
instance (Hashable a) => Hashable (SendPort a) where
instance (NFData a) => NFData (SendPort a) where rnf (SendPort x) = x `seq` ()

-- | The receive end of a typed channel (not serializable)
--
-- Note that 'ReceivePort' implements 'Functor', 'Applicative', 'Alternative'
-- and 'Monad'. This is especially useful when merging receive ports.
newtype ReceivePort a = ReceivePort { receiveSTM :: STM a }
  deriving (Typeable, Functor, Applicative, Alternative, Monad)

{-
data ReceivePort a =
    -- | A single receive port
    ReceivePortSingle (TQueue a)
    -- | A left-biased combination of receive ports
  | ReceivePortBiased [ReceivePort a]
    -- | A round-robin combination of receive ports
  | ReceivePortRR (TVar [ReceivePort a])
  deriving Typeable
-}

--------------------------------------------------------------------------------
-- Messages                                                                   --
--------------------------------------------------------------------------------

-- | Messages consist of their typeRep fingerprint and their encoding
data Message =
  EncodedMessage
  { messageFingerprint :: !Fingerprint
  , messageEncoding    :: !BSL.ByteString
  } |
  forall a . Serializable a =>
  UnencodedMessage
  {
    messageFingerprint :: !Fingerprint
  , messagePayload     :: !a
  }
  deriving (Typeable)

instance NFData Message where
#if MIN_VERSION_bytestring(0,10,0)
  rnf (EncodedMessage _ e) = rnf e `seq` ()
#else
  rnf (EncodedMessage _ e) = BSL.length e `seq` ()
#endif
  rnf (UnencodedMessage _ a) = a `seq` ()   -- forced to WHNF only

instance Show Message where
  show (EncodedMessage fp enc) = show enc ++ " :: " ++ showFingerprint fp []
  show (UnencodedMessage _ uenc) = "[unencoded message] :: " ++ (show $ typeOf uenc)

-- | /internal use only/.
isEncoded :: Message -> Bool
isEncoded (EncodedMessage _ _) = True
isEncoded _                    = False
-- [note] isEncoded:
-- This is just as internal as it looks and yes, it does feel a bit odd that
-- we're exporting it for use, however DPP does a /lot/ of work with low
-- level APIs such as unwrapMessage and handleMessage, and in the process
-- tries very hard to avoid copying (and re-serialisation) where possible.
-- Being able to determine that a message is encoded (or otherwise) makes
-- that a lot more manageable.

-- | Turn any serialiable term into a message
createMessage :: Serializable a => a -> Message
createMessage a = EncodedMessage (fingerprint a) (encode a)

-- | Turn any serializable term into an unencoded/local message
createUnencodedMessage :: Serializable a => a -> Message
createUnencodedMessage a =
  let encoded = encode a in BSL.length encoded `seq` UnencodedMessage (fingerprint a) a

-- | Turn any serializable term into an unencodede/local message, without
-- evalutaing it! This is a dangerous business.
unsafeCreateUnencodedMessage :: Serializable a => a -> Message
unsafeCreateUnencodedMessage a = UnencodedMessage (fingerprint a) a

-- | Serialize a message
messageToPayload :: Message -> [BSS.ByteString]
messageToPayload (EncodedMessage fp enc) = encodeFingerprint fp : BSL.toChunks enc
messageToPayload (UnencodedMessage fp m) = messageToPayload ((EncodedMessage fp (encode m)))

-- | Deserialize a message
payloadToMessage :: [BSS.ByteString] -> Message
payloadToMessage payload = EncodedMessage fp (copy msg)
  where
    encFp :: BSL.ByteString
    msg   :: BSL.ByteString
    (encFp, msg) = BSL.splitAt (fromIntegral sizeOfFingerprint)
                 $ BSL.fromChunks payload

    fp :: Fingerprint
    fp = decodeFingerprint . BSS.concat . BSL.toChunks $ encFp

    copy :: BSL.ByteString -> BSL.ByteString
    copy (BSL.Chunk bs BSL.Empty) = BSL.Chunk (BSS.copy bs) BSL.Empty
    copy bsl = BSL.fromChunks . return . BSS.concat . BSL.toChunks $ bsl

--------------------------------------------------------------------------------
-- Node controller user-visible data types                                    --
--------------------------------------------------------------------------------

-- | MonitorRef is opaque for regular Cloud Haskell processes
data MonitorRef = MonitorRef
  { -- | ID of the entity to be monitored
    monitorRefIdent   :: !Identifier
    -- | Unique to distinguish multiple monitor requests by the same process
  , monitorRefCounter :: !Int32
  }
  deriving (Eq, Ord, Show, Typeable, Generic)
instance Hashable MonitorRef

instance NFData MonitorRef where
  rnf (MonitorRef i _) = rnf i `seq` ()

-- | Message sent by process monitors
data ProcessMonitorNotification =
    ProcessMonitorNotification !MonitorRef !ProcessId !DiedReason
  deriving (Typeable, Show)

-- | Message sent by node monitors
data NodeMonitorNotification =
    NodeMonitorNotification !MonitorRef !NodeId !DiedReason
  deriving (Typeable, Show)

-- | Message sent by channel (port) monitors
data PortMonitorNotification =
    PortMonitorNotification !MonitorRef !SendPortId !DiedReason
  deriving (Typeable, Show)

-- | Exceptions thrown when a linked process dies
data ProcessLinkException =
    ProcessLinkException !ProcessId !DiedReason
  deriving (Typeable, Show)

-- | Exception thrown when a linked node dies
data NodeLinkException =
    NodeLinkException !NodeId !DiedReason
  deriving (Typeable, Show)

-- | Exception thrown when a linked channel (port) dies
data PortLinkException =
    PortLinkException !SendPortId !DiedReason
  deriving (Typeable, Show)

-- | Exception thrown when a process attempts to register
-- a process under an already-registered name or to
-- unregister a name that hasn't been registered
data ProcessRegistrationException =
    ProcessRegistrationException !String
  deriving (Typeable, Show)

-- | Internal exception thrown indirectly by 'exit'
data ProcessExitException =
    ProcessExitException !ProcessId !Message
  deriving Typeable

instance Exception ProcessExitException
instance Show ProcessExitException where
  show (ProcessExitException pid _) = "exit-from=" ++ (show pid)

instance Exception ProcessLinkException
instance Exception NodeLinkException
instance Exception PortLinkException
instance Exception ProcessRegistrationException

-- | Why did a process die?
data DiedReason =
    -- | Normal termination
    DiedNormal
    -- | The process exited with an exception
    -- (provided as 'String' because 'Exception' does not implement 'Binary')
  | DiedException !String
    -- | We got disconnected from the process node
  | DiedDisconnect
    -- | The process node died
  | DiedNodeDown
    -- | Invalid (process/node/channel) identifier
  | DiedUnknownId
  deriving (Show, Eq)

instance NFData DiedReason where
  rnf (DiedException s) = rnf s `seq` ()
  rnf x = x `seq` ()

-- | (Asynchronous) reply from unmonitor
newtype DidUnmonitor = DidUnmonitor MonitorRef
  deriving (Typeable, Binary)

-- | (Asynchronous) reply from unlink
newtype DidUnlinkProcess = DidUnlinkProcess ProcessId
  deriving (Typeable, Binary)

-- | (Asynchronous) reply from unlinkNode
newtype DidUnlinkNode = DidUnlinkNode NodeId
  deriving (Typeable, Binary)

-- | (Asynchronous) reply from unlinkPort
newtype DidUnlinkPort = DidUnlinkPort SendPortId
  deriving (Typeable, Binary)

-- | 'SpawnRef' are used to return pids of spawned processes
newtype SpawnRef = SpawnRef Int32
  deriving (Show, Binary, Typeable, Eq)

-- | (Asynchronius) reply from 'spawn'
data DidSpawn = DidSpawn SpawnRef ProcessId
  deriving (Show, Typeable)

-- | (Asynchronous) reply from 'whereis'
data WhereIsReply = WhereIsReply String (Maybe ProcessId)
  deriving (Show, Typeable)

-- | (Asynchronous) reply from 'register' and 'unregister'
data RegisterReply = RegisterReply String Bool
  deriving (Show, Typeable)

data NodeStats = NodeStats {
     nodeStatsNode            :: NodeId
   , nodeStatsRegisteredNames :: Int
   , nodeStatsMonitors        :: Int
   , nodeStatsLinks           :: Int
   , nodeStatsProcesses       :: Int
   }
   deriving (Show, Eq, Typeable)

-- | Provide information about a running process
data ProcessInfo = ProcessInfo {
    infoNode               :: NodeId
  , infoRegisteredNames    :: [String]
  , infoMessageQueueLength :: Maybe Int
  , infoMonitors           :: [(ProcessId, MonitorRef)]
  , infoLinks              :: [ProcessId]
  } deriving (Show, Eq, Typeable)

data ProcessInfoNone = ProcessInfoNone DiedReason
    deriving (Show, Typeable)

--------------------------------------------------------------------------------
-- Node controller internal data types                                        --
--------------------------------------------------------------------------------

-- | Messages to the node controller
data NCMsg = NCMsg
  { ctrlMsgSender :: !Identifier
  , ctrlMsgSignal :: !ProcessSignal
  }
  deriving Show

-- | Signals to the node controller (see 'NCMsg')
data ProcessSignal =
    Link !Identifier
  | Unlink !Identifier
  | Monitor !MonitorRef
  | Unmonitor !MonitorRef
  | Died Identifier !DiedReason
  | Spawn !(Closure (Process ())) !SpawnRef
  | WhereIs !String
  | Register !String !NodeId !(Maybe ProcessId) !Bool -- Use 'Nothing' to unregister, use True to force reregister
  | NamedSend !String !Message
  | LocalSend !ProcessId !Message
  | LocalPortSend !SendPortId !Message
  | Kill !ProcessId !String
  | Exit !ProcessId !Message
  | GetInfo !ProcessId
  | SigShutdown
  | GetNodeStats !NodeId
  deriving Show

--------------------------------------------------------------------------------
-- Binary instances                                                           --
--------------------------------------------------------------------------------

instance Binary Message where
  put msg = put $ messageToPayload msg
  get = payloadToMessage <$> get

instance Binary LocalProcessId where
  put lpid = put (lpidUnique lpid) >> put (lpidCounter lpid)
  get      = LocalProcessId <$> get <*> get

instance Binary ProcessMonitorNotification where
  put (ProcessMonitorNotification ref pid reason) = put ref >> put pid >> put reason
  get = ProcessMonitorNotification <$> get <*> get <*> get

instance Binary NodeMonitorNotification where
  put (NodeMonitorNotification ref pid reason) = put ref >> put pid >> put reason
  get = NodeMonitorNotification <$> get <*> get <*> get

instance Binary PortMonitorNotification where
  put (PortMonitorNotification ref pid reason) = put ref >> put pid >> put reason
  get = PortMonitorNotification <$> get <*> get <*> get

instance Binary NCMsg where
  put msg = put (ctrlMsgSender msg) >> put (ctrlMsgSignal msg)
  get     = NCMsg <$> get <*> get

instance Binary MonitorRef where
  put ref = put (monitorRefIdent ref) >> put (monitorRefCounter ref)
  get     = MonitorRef <$> get <*> get

instance Binary ProcessSignal where
  put (Link pid)              = putWord8 0 >> put pid
  put (Unlink pid)            = putWord8 1 >> put pid
  put (Monitor ref)           = putWord8 2 >> put ref
  put (Unmonitor ref)         = putWord8 3 >> put ref
  put (Died who reason)       = putWord8 4 >> put who >> put reason
  put (Spawn proc ref)        = putWord8 5 >> put proc >> put ref
  put (WhereIs label)         = putWord8 6 >> put label
  put (Register label nid pid force) = putWord8 7 >> put label >> put nid >> put pid >> put force
  put (NamedSend label msg)   = putWord8 8 >> put label >> put (messageToPayload msg)
  put (Kill pid reason)       = putWord8 9 >> put pid >> put reason
  put (Exit pid reason)       = putWord8 10 >> put pid >> put (messageToPayload reason)
  put (LocalSend to' msg)      = putWord8 11 >> put to' >> put (messageToPayload msg)
  put (LocalPortSend sid msg) = putWord8 12 >> put sid >> put (messageToPayload msg)
  put (GetInfo about)         = putWord8 30 >> put about
  put (SigShutdown)         = putWord8 31
  put (GetNodeStats nid)         = putWord8 32 >> put nid
  get = do
    header <- getWord8
    case header of
      0  -> Link <$> get
      1  -> Unlink <$> get
      2  -> Monitor <$> get
      3  -> Unmonitor <$> get
      4  -> Died <$> get <*> get
      5  -> Spawn <$> get <*> get
      6  -> WhereIs <$> get
      7  -> Register <$> get <*> get <*> get <*> get
      8  -> NamedSend <$> get <*> (payloadToMessage <$> get)
      9  -> Kill <$> get <*> get
      10 -> Exit <$> get <*> (payloadToMessage <$> get)
      11 -> LocalSend <$> get <*> (payloadToMessage <$> get)
      12 -> LocalPortSend <$> get <*> (payloadToMessage <$> get)
      30 -> GetInfo <$> get
      31 -> return SigShutdown
      32 -> GetNodeStats <$> get
      _ -> fail "ProcessSignal.get: invalid"

instance Binary DiedReason where
  put DiedNormal        = putWord8 0
  put (DiedException e) = putWord8 1 >> put e
  put DiedDisconnect    = putWord8 2
  put DiedNodeDown      = putWord8 3
  put DiedUnknownId     = putWord8 4
  get = do
    header <- getWord8
    case header of
      0 -> return DiedNormal
      1 -> DiedException <$> get
      2 -> return DiedDisconnect
      3 -> return DiedNodeDown
      4 -> return DiedUnknownId
      _ -> fail "DiedReason.get: invalid"

instance Binary DidSpawn where
  put (DidSpawn ref pid) = put ref >> put pid
  get = DidSpawn <$> get <*> get

instance Binary SendPortId where
  put cid = put (sendPortProcessId cid) >> put (sendPortLocalId cid)
  get = SendPortId <$> get <*> get

instance Binary Identifier where
  put (ProcessIdentifier pid)  = putWord8 0 >> put pid
  put (NodeIdentifier nid)     = putWord8 1 >> put nid
  put (SendPortIdentifier cid) = putWord8 2 >> put cid
  get = do
    header <- getWord8
    case header of
      0 -> ProcessIdentifier <$> get
      1 -> NodeIdentifier <$> get
      2 -> SendPortIdentifier <$> get
      _ -> fail "Identifier.get: invalid"

instance Binary WhereIsReply where
  put (WhereIsReply label mPid) = put label >> put mPid
  get = WhereIsReply <$> get <*> get

instance Binary RegisterReply where
  put (RegisterReply label ok) = put label >> put ok
  get = RegisterReply <$> get <*> get

instance Binary ProcessInfo where
  get = ProcessInfo <$> get <*> get <*> get <*> get <*> get
  put pInfo = put (infoNode pInfo)
           >> put (infoRegisteredNames pInfo)
           >> put (infoMessageQueueLength pInfo)
           >> put (infoMonitors pInfo)
           >> put (infoLinks pInfo)

instance Binary NodeStats where
  get = NodeStats <$> get <*> get <*> get <*> get <*> get
  put nStats =  put (nodeStatsNode nStats)
             >> put (nodeStatsRegisteredNames nStats)
             >> put (nodeStatsMonitors nStats)
             >> put (nodeStatsLinks nStats)
             >> put (nodeStatsProcesses nStats)

instance Binary ProcessInfoNone where
  get = ProcessInfoNone <$> get
  put (ProcessInfoNone r) = put r

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localProcesses :: Accessor LocalNodeState (Map LocalProcessId LocalProcess)
localProcesses = accessor _localProcesses (\procs st -> st { _localProcesses = procs })

localPidCounter :: Accessor LocalNodeState Int32
localPidCounter = accessor _localPidCounter (\ctr st -> st { _localPidCounter = ctr })

localPidUnique :: Accessor LocalNodeState Int32
localPidUnique = accessor _localPidUnique (\unq st -> st { _localPidUnique = unq })

localConnections :: Accessor LocalNodeState (Map (Identifier, Identifier) (NT.Connection, ImplicitReconnect))
localConnections = accessor _localConnections (\conns st -> st { _localConnections = conns })

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe LocalProcess)
localProcessWithId lpid = localProcesses >>> DAC.mapMaybe lpid

localConnectionBetween :: Identifier -> Identifier -> Accessor LocalNodeState (Maybe (NT.Connection, ImplicitReconnect))
localConnectionBetween from' to' = localConnections >>> DAC.mapMaybe (from', to')

monitorCounter :: Accessor LocalProcessState Int32
monitorCounter = accessor _monitorCounter (\cnt st -> st { _monitorCounter = cnt })

spawnCounter :: Accessor LocalProcessState Int32
spawnCounter = accessor _spawnCounter (\cnt st -> st { _spawnCounter = cnt })

channelCounter :: Accessor LocalProcessState LocalSendPortId
channelCounter = accessor _channelCounter (\cnt st -> st { _channelCounter = cnt })

typedChannels :: Accessor LocalProcessState (Map LocalSendPortId TypedChannel)
typedChannels = accessor _typedChannels (\cs st -> st { _typedChannels = cs })

typedChannelWithId :: LocalSendPortId -> Accessor LocalProcessState (Maybe TypedChannel)
typedChannelWithId cid = typedChannels >>> DAC.mapMaybe cid

--------------------------------------------------------------------------------
-- Utilities                                                                  --
--------------------------------------------------------------------------------

-- Like 'Control.Monad.forever' but sans space leak
{-# INLINE forever' #-}
forever' :: Monad m => m a -> m b
forever' a = let a' = a >> a' in a'

