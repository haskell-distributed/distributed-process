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
    -- * Local nodes and processes
  , LocalNode(..)
  , LocalNodeState(..)
  , LocalProcess(..)
  , LocalProcessState(..)
  , Process(..)
  , runLocalProcess
    -- * Typed channels
  , LocalSendPortId 
  , SendPortId(..)
  , TypedChannel(..)
  , SendPort(..)
  , ReceivePort(..)
    -- * Messages 
  , Message(..)
  , createMessage
  , messageToPayload
  , payloadToMessage
    -- * Node controller user-visible data types 
  , MonitorRef(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , DiedReason(..)
  , DidUnmonitor(..)
  , DidUnlinkProcess(..)
  , DidUnlinkNode(..)
  , DidUnlinkPort(..)
  , SpawnRef(..)
  , DidSpawn(..)
  , WhereIsReply(..)
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
  ) where

import Data.Map (Map)
import Data.Int (Int32)
import Data.Typeable (Typeable)
import Data.Binary (Binary(put, get), putWord8, getWord8, encode)
import qualified Data.ByteString as BSS (ByteString, concat)
import qualified Data.ByteString.Lazy as BSL 
  ( ByteString
  , toChunks
  , splitAt
  , fromChunks
  )
import Data.Accessor (Accessor, accessor)
import qualified Data.Accessor.Container as DAC (mapMaybe)
import Control.Category ((>>>))
import Control.Exception (Exception)
import Control.Concurrent (ThreadId)
import Control.Concurrent.Chan (Chan)
import Control.Concurrent.STM (TChan, TVar)
import qualified Network.Transport as NT (EndPoint, EndPointAddress, Connection)
import Control.Applicative (Applicative, (<$>), (<*>))
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
import Control.Distributed.Static (RemoteTable, Closure)

-- import Control.Distributed.Process.Internal.Dynamic (Dynamic) 
-- import Control.Distributed.Process.Internal.TypeRep (compareTypeRep) -- and Binary instances

--------------------------------------------------------------------------------
-- Node and process identifiers                                               --
--------------------------------------------------------------------------------

-- | Node identifier 
newtype NodeId = NodeId { nodeAddress :: NT.EndPointAddress }
  deriving (Eq, Ord, Binary)

instance Show NodeId where
  show (NodeId addr) = "nid://" ++ show addr 

-- | A local process ID consists of a seed which distinguishes processes from
-- different instances of the same local node and a counter
data LocalProcessId = LocalProcessId 
  { lpidUnique  :: {-# UNPACK #-} !Int32
  , lpidCounter :: {-# UNPACK #-} !Int32
  }
  deriving (Eq, Ord, Typeable, Show)

-- | Process identifier
data ProcessId = ProcessId 
  { -- | The ID of the node the process is running on
    processNodeId  :: !NodeId
    -- | Node-local identifier for the process
  , processLocalId :: {-# UNPACK #-} !LocalProcessId 
  }
  deriving (Eq, Ord, Typeable)

instance Show ProcessId where
  show (ProcessId (NodeId addr) (LocalProcessId _ lid)) 
    = "pid://" ++ show addr ++ ":" ++ show lid

-- | Union of all kinds of identifiers 
data Identifier = 
    NodeIdentifier NodeId
  | ProcessIdentifier ProcessId 
  | SendPortIdentifier SendPortId
  deriving (Eq, Ord)

instance Show Identifier where
  show (NodeIdentifier nid)     = show nid
  show (ProcessIdentifier pid)  = show pid
  show (SendPortIdentifier cid) = show cid

nodeOf :: Identifier -> NodeId
nodeOf (NodeIdentifier nid)     = nid
nodeOf (ProcessIdentifier pid)  = processNodeId pid
nodeOf (SendPortIdentifier cid) = processNodeId (sendPortProcessId cid)

--------------------------------------------------------------------------------
-- Local nodes and processes                                                  --
--------------------------------------------------------------------------------

-- | Local nodes
data LocalNode = LocalNode 
  { -- | 'NodeId' of the node
    localNodeId :: NodeId
    -- | The network endpoint associated with this node 
  , localEndPoint :: NT.EndPoint 
    -- | Local node state 
  , localState :: StrictMVar LocalNodeState
    -- | Channel for the node controller
  , localCtrlChan :: Chan NCMsg
    -- | Runtime lookup table for supporting closures
    -- TODO: this should be part of the CH state, not the local endpoint state
  , remoteTable :: RemoteTable 
  }

-- | Local node state
data LocalNodeState = LocalNodeState 
  { _localProcesses   :: !(Map LocalProcessId LocalProcess)
  , _localPidCounter  :: !Int32
  , _localPidUnique   :: !Int32
  , _localConnections :: !(Map (Identifier, Identifier) NT.Connection)
  }

-- | Processes running on our local node
data LocalProcess = LocalProcess 
  { processQueue  :: CQueue Message 
  , processId     :: ProcessId
  , processState  :: StrictMVar LocalProcessState
  , processThread :: ThreadId
  , processNode   :: LocalNode
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
  deriving (Eq, Ord)

instance Show SendPortId where
  show (SendPortId (ProcessId (NodeId addr) (LocalProcessId _ plid)) clid)  
    = "cid://" ++ show addr ++ ":" ++ show plid ++ ":" ++ show clid

data TypedChannel = forall a. Serializable a => TypedChannel (TChan a)

-- | The send send of a typed channel (serializable)
newtype SendPort a = SendPort { 
    -- | The (unique) ID of this send port
    sendPortId :: SendPortId 
  }
  deriving (Typeable, Binary, Show, Eq, Ord)

-- | The receive end of a typed channel (not serializable)
data ReceivePort a = 
    -- | A single receive port
    ReceivePortSingle (TChan a)
    -- | A left-biased combination of receive ports 
  | ReceivePortBiased [ReceivePort a] 
    -- | A round-robin combination of receive ports
  | ReceivePortRR (TVar [ReceivePort a]) 
  deriving Typeable

--------------------------------------------------------------------------------
-- Messages                                                                   --
--------------------------------------------------------------------------------

-- | Messages consist of their typeRep fingerprint and their encoding
data Message = Message 
  { messageFingerprint :: Fingerprint 
  , messageEncoding    :: BSL.ByteString
  }

instance Show Message where
  show (Message fp enc) = show enc ++ " :: " ++ showFingerprint fp [] 

-- | Turn any serialiable term into a message
createMessage :: Serializable a => a -> Message
createMessage a = Message (fingerprint a) (encode a)

-- | Serialize a message
messageToPayload :: Message -> [BSS.ByteString]
messageToPayload (Message fp enc) = encodeFingerprint fp : BSL.toChunks enc

-- | Deserialize a message
payloadToMessage :: [BSS.ByteString] -> Message
payloadToMessage payload = Message fp msg
  where
    (encFp, msg) = BSL.splitAt (fromIntegral sizeOfFingerprint) 
                 $ BSL.fromChunks payload 
    fp = decodeFingerprint . BSS.concat . BSL.toChunks $ encFp

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
  deriving (Eq, Ord, Show)

-- | Message sent by process monitors
data ProcessMonitorNotification = 
    ProcessMonitorNotification MonitorRef ProcessId DiedReason
  deriving (Typeable, Show)

-- | Message sent by node monitors
data NodeMonitorNotification = 
    NodeMonitorNotification MonitorRef NodeId DiedReason
  deriving (Typeable, Show)

-- | Message sent by channel (port) monitors
data PortMonitorNotification = 
    PortMonitorNotification MonitorRef SendPortId DiedReason
  deriving (Typeable, Show)

-- | Exceptions thrown when a linked process dies
data ProcessLinkException = 
    ProcessLinkException ProcessId DiedReason
  deriving (Typeable, Show)

-- | Exception thrown when a linked node dies
data NodeLinkException = 
    NodeLinkException NodeId DiedReason
  deriving (Typeable, Show)

-- | Exception thrown when a linked channel (port) dies
data PortLinkException = 
    PortLinkException SendPortId DiedReason
  deriving (Typeable, Show)

instance Exception ProcessLinkException
instance Exception NodeLinkException
instance Exception PortLinkException

-- | Why did a process die?
data DiedReason = 
    -- | Normal termination
    DiedNormal
    -- | The process exited with an exception
    -- (provided as 'String' because 'Exception' does not implement 'Binary')
  | DiedException String
    -- | We got disconnected from the process node
  | DiedDisconnect
    -- | The process node died
  | DiedNodeDown
    -- | Invalid (process/node/channel) identifier 
  | DiedUnknownId
  deriving (Show, Eq)

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

--------------------------------------------------------------------------------
-- Node controller internal data types                                        --
--------------------------------------------------------------------------------

-- | Messages to the node controller
data NCMsg = NCMsg 
  { ctrlMsgSender :: Identifier 
  , ctrlMsgSignal :: ProcessSignal
  }
  deriving Show

-- | Signals to the node controller (see 'NCMsg')
data ProcessSignal =
    Link Identifier 
  | Unlink Identifier 
  | Monitor MonitorRef
  | Unmonitor MonitorRef
  | Died Identifier DiedReason
  | Spawn (Closure (Process ())) SpawnRef 
  | WhereIs String
  | Register String (Maybe ProcessId) -- Nothing to unregister
  | NamedSend String Message
  | Reconnect Identifier
  deriving Show

--------------------------------------------------------------------------------
-- Binary instances                                                           --
--------------------------------------------------------------------------------

instance Binary LocalProcessId where
  put lpid = put (lpidUnique lpid) >> put (lpidCounter lpid)
  get      = LocalProcessId <$> get <*> get

instance Binary ProcessId where
  put pid = put (processNodeId pid) >> put (processLocalId pid)
  get     = ProcessId <$> get <*> get

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
  put (Link pid)            = putWord8 0 >> put pid
  put (Unlink pid)          = putWord8 1 >> put pid
  put (Monitor ref)         = putWord8 2 >> put ref
  put (Unmonitor ref)       = putWord8 3 >> put ref 
  put (Died who reason)     = putWord8 4 >> put who >> put reason
  put (Spawn proc ref)      = putWord8 5 >> put proc >> put ref
  put (WhereIs label)       = putWord8 6 >> put label
  put (Register label pid)  = putWord8 7 >> put label >> put pid
  put (NamedSend label msg) = putWord8 8 >> put label >> put (messageToPayload msg) 
  put (Reconnect dest)      = putWord8 9 >> put dest
  get = do
    header <- getWord8
    case header of
      0 -> Link <$> get
      1 -> Unlink <$> get
      2 -> Monitor <$> get
      3 -> Unmonitor <$> get
      4 -> Died <$> get <*> get
      5 -> Spawn <$> get <*> get
      6 -> WhereIs <$> get
      7 -> Register <$> get <*> get
      8 -> NamedSend <$> get <*> (payloadToMessage <$> get)
      9 -> Reconnect <$> get
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

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localProcesses :: Accessor LocalNodeState (Map LocalProcessId LocalProcess)
localProcesses = accessor _localProcesses (\procs st -> st { _localProcesses = procs })

localPidCounter :: Accessor LocalNodeState Int32
localPidCounter = accessor _localPidCounter (\ctr st -> st { _localPidCounter = ctr })

localPidUnique :: Accessor LocalNodeState Int32
localPidUnique = accessor _localPidUnique (\unq st -> st { _localPidUnique = unq })

localConnections :: Accessor LocalNodeState (Map (Identifier, Identifier) NT.Connection)
localConnections = accessor _localConnections (\conns st -> st { _localConnections = conns })

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe LocalProcess)
localProcessWithId lpid = localProcesses >>> DAC.mapMaybe lpid

localConnectionBetween :: Identifier -> Identifier -> Accessor LocalNodeState (Maybe NT.Connection)
localConnectionBetween from to = localConnections >>> DAC.mapMaybe (from, to)

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
