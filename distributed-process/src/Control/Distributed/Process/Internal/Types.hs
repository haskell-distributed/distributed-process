-- | Types used throughout the Cloud Haskell framework
--
-- We collect all types used internally in a single module because 
-- many of these data types are mutually recursive and cannot be split across
-- modules.
{-# LANGUAGE MagicHash #-}
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
  , procMsg
    -- * Typed channels
  , LocalSendPortId 
  , SendPortId(..)
  , TypedChannel(..)
  , SendPort(..)
  , ReceivePort(..)
    -- * Closures
  , StaticLabel(..)
  , Static(..) 
  , Closure(..)
  , RemoteTable(..)
  , SerializableDict(..)
  , RuntimeSerializableSupport(..)
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
    -- * MessageT monad
  , MessageT(..)
  , MessageState(..)
    -- * Accessors
  , localProcesses
  , localPidCounter
  , localPidUnique
  , localProcessWithId
  , monitorCounter
  , spawnCounter
  , channelCounter
  , typedChannels
  , typedChannelWithId
  , remoteTableLabels
  , remoteTableDicts
  , remoteTableLabel
  , remoteTableDict
  ) where

import Data.Map (Map)
import Data.Int (Int32)
import Data.Typeable (Typeable, TypeRep)
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
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.Chan (Chan)
import Control.Concurrent.STM (TChan, TVar)
import qualified Network.Transport as NT (EndPoint, EndPointAddress, Connection)
import Control.Applicative (Applicative, (<$>), (<*>))
import Control.Monad.Reader (MonadReader(..), ReaderT)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.State (MonadState, StateT)
import qualified Control.Monad.Trans.Class as Trans (lift)
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
import Control.Distributed.Process.Internal.Dynamic (Dynamic) 

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
  { lpidUnique  :: Int32
  , lpidCounter :: Int32
  }
  deriving (Eq, Ord, Typeable)

instance Show LocalProcessId where
  show = show . lpidCounter 

-- | Process identifier
data ProcessId = ProcessId 
  { processNodeId  :: NodeId
  , processLocalId :: LocalProcessId 
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
  , localState :: MVar LocalNodeState
    -- | Channel for the node controller
  , localCtrlChan :: Chan NCMsg
    -- | Runtime lookup table for supporting closures
    -- TODO: this should be part of the CH state, not the local endpoint state
  , remoteTable :: RemoteTable 
  }

-- | Local node state
data LocalNodeState = LocalNodeState 
  { _localProcesses  :: Map LocalProcessId LocalProcess
  , _localPidCounter :: Int32
  , _localPidUnique  :: Int32
  }

-- | Processes running on our local node
data LocalProcess = LocalProcess 
  { processQueue  :: CQueue Message 
  , processId     :: ProcessId
  , processState  :: MVar LocalProcessState
  , processThread :: ThreadId
  }

-- | Local process state
data LocalProcessState = LocalProcessState
  { _monitorCounter :: Int32
  , _spawnCounter   :: Int32
  , _channelCounter :: Int32
  , _typedChannels  :: Map LocalSendPortId TypedChannel 
  }

-- | The Cloud Haskell 'Process' type
newtype Process a = Process { 
    unProcess :: ReaderT LocalProcess (MessageT IO) a 
  }
  deriving (Functor, Monad, MonadIO, MonadReader LocalProcess, Typeable, Applicative)

procMsg :: MessageT IO a -> Process a
procMsg = Process . Trans.lift 

--------------------------------------------------------------------------------
-- Typed channels                                                             --
--------------------------------------------------------------------------------

type LocalSendPortId = Int32

data SendPortId = SendPortId {
    sendPortProcessId :: ProcessId
  , sendPortLocalId   :: LocalSendPortId
  }
  deriving (Eq, Ord)

instance Show SendPortId where
  show (SendPortId (ProcessId (NodeId addr) (LocalProcessId _ plid)) clid)  
    = "cid://" ++ show addr ++ ":" ++ show plid ++ ":" ++ show clid

data TypedChannel = forall a. Serializable a => TypedChannel (TChan a)

-- | The send send of a typed channel (serializable)
newtype SendPort a = SendPort { sendPortId :: SendPortId }
  deriving (Typeable, Binary, Show, Eq, Ord)

-- | The receive end of a typed channel (not serializable)
data ReceivePort a = 
    -- | A single receive port
    ReceivePortSingle (TChan a)
    -- | A left-biased combination of receive ports 
  | ReceivePortBiased [ReceivePort a] 
    -- | A round-robin combination of receive ports
  | ReceivePortRR (TVar [ReceivePort a]) 

--------------------------------------------------------------------------------
-- Closures                                                                   --
--------------------------------------------------------------------------------

data StaticLabel = 
    UserStatic String
  -- Built-in closures 
  | ClosureReturn
  | ClosureSend 
  | ClosureExpect
  -- Generic closure combinators
  | ClosureApply
  | ClosureConst
  | ClosureUnit
  -- Arrow combinators for processes
  | CpId
  | CpComp 
  | CpFirst
  | CpSwap
  | CpCopy
  | CpLeft
  | CpMirror
  | CpUntag
  | CpApply
  deriving (Typeable, Show)

-- | A static value is one that is bound at top-level.
newtype Static a = Static StaticLabel 
  deriving (Typeable, Show)

-- | A closure is a static value and an encoded environment
data Closure a = Closure (Static (BSL.ByteString -> a)) BSL.ByteString
  deriving (Typeable, Show)

-- | Used to fake 'static' (see paper)
data RemoteTable = RemoteTable {
    -- | If the user creates a closure of type @a -> Closure b@ from a function
    -- @f : a -> b@, then '_remoteTableLabels' should have an entry for "f"
    -- of type @ByteString -> b@ (basically, @f . encode@)
    _remoteTableLabels  :: Map String Dynamic 
    -- | Runtime counterpart to SerializableDict 
  , _remoteTableDicts   :: Map TypeRep RuntimeSerializableSupport 
  }

-- | Reification of 'Serializable' (see "Control.Distributed.Process.Closure")
data SerializableDict a where
    SerializableDict :: Serializable a => SerializableDict a
  deriving (Typeable)

-- | Runtime support for implementing "polymorphic" functions with a 
-- Serializable qualifier (sendClosure, returnClosure, ..). 
--
-- We don't attempt to keep this minimal, but instead just add functions as
-- convenient. This will be replaced anyway once 'static' has been implemented.
data RuntimeSerializableSupport = RuntimeSerializableSupport {
   rssSend   :: Dynamic
 , rssReturn :: Dynamic
 , rssExpect :: Dynamic
 }

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
    monitorRefIdent   :: Identifier
    -- | Unique to distinguish multiple monitor requests by the same process
  , monitorRefCounter :: Int32
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

instance Binary (Closure a) where
  put (Closure (Static label) env) = put label >> put env
  get = Closure <$> (Static <$> get) <*> get 

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

instance Binary StaticLabel where
  put (UserStatic string) = putWord8 0 >> put string
  put ClosureReturn = putWord8 1
  put ClosureSend   = putWord8 2
  put ClosureExpect = putWord8 3
  put ClosureApply  = putWord8 4
  put ClosureConst  = putWord8 5
  put ClosureUnit   = putWord8 6
  put CpId          = putWord8 7
  put CpComp        = putWord8 8
  put CpFirst       = putWord8 9
  put CpSwap        = putWord8 10
  put CpCopy        = putWord8 11 
  put CpLeft        = putWord8 12
  put CpMirror      = putWord8 13
  put CpUntag       = putWord8 14
  put CpApply       = putWord8 15
  get = do
    header <- getWord8
    case header of
      0  -> UserStatic <$> get
      1  -> return ClosureReturn
      2  -> return ClosureSend 
      3  -> return ClosureExpect 
      4  -> return ClosureApply
      5  -> return ClosureConst
      6  -> return ClosureUnit
      7  -> return CpId
      8  -> return CpComp 
      9  -> return CpFirst
      10 -> return CpSwap
      11 -> return CpCopy
      12 -> return CpLeft
      13 -> return CpMirror
      14 -> return CpUntag
      15 -> return CpApply
      _  -> fail "StaticLabel.get: invalid"

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

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe LocalProcess)
localProcessWithId lpid = localProcesses >>> DAC.mapMaybe lpid

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

remoteTableLabels :: Accessor RemoteTable (Map String Dynamic)
remoteTableLabels = accessor _remoteTableLabels (\ls tbl -> tbl { _remoteTableLabels = ls })

remoteTableDicts :: Accessor RemoteTable (Map TypeRep RuntimeSerializableSupport)
remoteTableDicts = accessor _remoteTableDicts (\ds tbl -> tbl { _remoteTableDicts = ds })

remoteTableLabel :: String -> Accessor RemoteTable (Maybe Dynamic)
remoteTableLabel label = remoteTableLabels >>> DAC.mapMaybe label

remoteTableDict :: TypeRep -> Accessor RemoteTable (Maybe RuntimeSerializableSupport)
remoteTableDict label = remoteTableDicts >>> DAC.mapMaybe label

--------------------------------------------------------------------------------
-- MessageT monad                                                             --
--------------------------------------------------------------------------------

newtype MessageT m a = MessageT { unMessageT :: StateT MessageState m a }
  deriving (Functor, Monad, MonadIO, MonadState MessageState, Applicative)

data MessageState = MessageState { 
     messageLocalNode   :: LocalNode
  , _messageConnections :: Map Identifier NT.Connection 
  }
