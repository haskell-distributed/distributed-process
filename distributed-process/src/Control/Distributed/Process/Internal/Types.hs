-- | We collect all types used internally in a single module to avoid using
-- mutually recursive modules
module Control.Distributed.Process.Internal.Types
  ( -- * Global CH state
    RemoteTable
  , initRemoteTable
  , -- * Node and process identifiers 
    NodeId(..)
  , LocalProcessId(..)
  , ProcessId(..)
  , Identifier(..)
    -- * Local nodes and processes
  , LocalNode(..)
  , LocalNodeState(..)
  , LocalProcess(..)
  , LocalProcessState(..)
  , Process(..)
  , runLocalProcess
    -- * Typed channels
  , LocalChannelId 
  , ChannelId(..)
  , TypedChannel(..)
  , SendPort(..)
  , ReceivePort(..)
    -- * Closures
  , Static(..) 
  , Closure(..)
    -- * Messages 
  , Message(..)
    -- * Node controller user-visible data types 
  , MonitorRef(..)
  , MonitorNotification(..)
  , LinkException(..)
  , DiedReason(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
  , SpawnRef(..)
  , DidSpawn(..)
    -- * Node controller internal data types 
  , NCMsg(..)
  , ProcessSignal(..)
    -- * Serialization/deserialization
  , createMessage
  , messageToPayload
  , payloadToMessage
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
    -- * MessageT monad
  , MessageT(..)
  , MessageState(..)
  , runMessageT
  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.Chan (Chan)
import Control.Category ((>>>))
import Control.Exception (Exception)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Int (Int32)
import Data.Typeable (Typeable)
import Data.Dynamic (Dynamic) 
import Data.Binary (Binary, encode, put, get, putWord8, getWord8)
import Data.ByteString.Lazy (ByteString)
import Data.Accessor (Accessor, accessor)
import qualified Data.Accessor.Container as DAC (mapMaybe)
import qualified Data.ByteString.Lazy as BSL (ByteString, toChunks, fromChunks, splitAt)
import qualified Data.ByteString as BSS (ByteString, concat)
import qualified Network.Transport as NT (EndPoint, EndPointAddress, Connection)
import Control.Applicative ((<$>), (<*>))
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.State (MonadState, StateT, evalStateT)
import Control.Distributed.Process.Serializable ( Fingerprint
                                                , Serializable
                                                , encodeFingerprint
                                                , decodeFingerprint
                                                , fingerprint
                                                , sizeOfFingerprint
                                                )
import Control.Distributed.Process.Internal.CQueue (CQueue)

--------------------------------------------------------------------------------
-- Global state                                                               --
--------------------------------------------------------------------------------

-- | Used to fake 'static' (see paper)
type RemoteTable = Map String Dynamic 

-- | Initial (empty) remote-call meta data
initRemoteTable :: RemoteTable
initRemoteTable = Map.empty

--------------------------------------------------------------------------------
-- Node and process identifiers                                               --
--------------------------------------------------------------------------------

-- | Node identifier 
newtype NodeId = NodeId { nodeAddress :: NT.EndPointAddress }
  deriving (Eq, Ord, Binary)

instance Show NodeId where
  show = show . nodeAddress

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
  show pid = show (processNodeId pid) ++ ":" ++ show (processLocalId pid)

-- | Union of all kinds of identifiers 
data Identifier = 
    ProcessIdentifier ProcessId 
  | NodeIdentifier NodeId
  | ChannelIdentifier ChannelId 
  deriving (Show, Eq, Ord)

--------------------------------------------------------------------------------
-- Local nodes and processes                                                  --
--------------------------------------------------------------------------------

-- | Local nodes
data LocalNode = LocalNode 
  { localNodeId   :: NodeId
  , localEndPoint :: NT.EndPoint 
  , localState    :: MVar LocalNodeState
  , localCtrlChan :: Chan NCMsg
  -- TODO: this should be part of the CH state, not the local endpoint state
  , remoteTable   :: RemoteTable 
  }

-- | Local node state
data LocalNodeState = LocalNodeState 
  { _localProcesses      :: Map LocalProcessId LocalProcess
  , _localPidCounter     :: Int32
  , _localPidUnique      :: Int32
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
  , _typedChannels  :: Map LocalChannelId TypedChannel 
  }

-- | The Cloud Haskell 'Process' type
newtype Process a = Process { 
    unProcess :: ReaderT LocalProcess (MessageT IO) a 
  }
  deriving (Functor, Monad, MonadIO, MonadReader LocalProcess, Typeable)

-- | Deconstructor for 'Process' (not exported to the public API) 
runLocalProcess :: LocalNode -> Process a -> LocalProcess -> IO a
runLocalProcess node proc = runMessageT node . runReaderT (unProcess proc) 

--------------------------------------------------------------------------------
-- Typed channels                                                             --
--------------------------------------------------------------------------------

type LocalChannelId = Int32

data ChannelId = ChannelId {
    channelProcessId :: ProcessId
  , channelLocalId   :: LocalChannelId
  }
  deriving (Show, Eq, Ord)

data TypedChannel = forall a. Serializable a => TypedChannel (CQueue a)

newtype SendPort a = SendPort ChannelId
newtype ReceivePort a = ReceivePort (CQueue a)

--------------------------------------------------------------------------------
-- Closures                                                                   --
--------------------------------------------------------------------------------

-- | A static value is one that is bound at top-level.
-- We represent it simply by a string
newtype Static a = Static String
  deriving (Typeable, Show)

-- | A closure is a static value and an encoded environment
data Closure a = Closure (Static (ByteString -> a)) ByteString
  deriving (Typeable, Show)

--------------------------------------------------------------------------------
-- Messages                                                                   --
--------------------------------------------------------------------------------

-- | Messages consist of their typeRep fingerprint and their encoding
data Message = Message 
  { messageFingerprint :: Fingerprint 
  , messageEncoding    :: BSL.ByteString
  }

--------------------------------------------------------------------------------
-- Node controller user-visible data types                                    --
--------------------------------------------------------------------------------

-- | MonitorRef is opaque for regular Cloud Haskell processes 
data MonitorRef = MonitorRef 
  { -- | PID of the process to be monitored (for routing purposes)
    monitorRefPid     :: ProcessId  
    -- | Unique to distinguish multiple monitor requests by the same process
  , monitorRefCounter :: Int32
  }
  deriving (Eq, Ord, Show)

-- | Messages sent by monitors
data MonitorNotification = MonitorNotification MonitorRef ProcessId DiedReason
  deriving (Typeable)

-- | Exceptions thrown when a linked process dies
data LinkException = LinkException ProcessId DiedReason
  deriving (Typeable, Show)

instance Exception LinkException

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
    -- | Invalid process ID
  | DiedNoProc
  deriving (Show, Eq)

-- | (Asynchronous) reply from unmonitor
newtype DidUnmonitor = DidUnmonitor MonitorRef
  deriving (Typeable, Binary)

-- | (Asynchronous) reply from unlink
newtype DidUnlink = DidUnlink ProcessId
  deriving (Typeable, Binary)

-- | 'SpawnRef' are used to return pids of spawned processes
newtype SpawnRef = SpawnRef Int32
  deriving (Show, Binary, Typeable, Eq)

-- | (Asynchronius) reply from spawn
data DidSpawn = DidSpawn SpawnRef ProcessId
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
    Link ProcessId
  | Unlink ProcessId
  | Monitor ProcessId MonitorRef
  | Unmonitor MonitorRef
  | Died Identifier DiedReason
  | Spawn (Closure (Process ())) SpawnRef 
  deriving Show

--------------------------------------------------------------------------------
-- Serialization/deserialization                                              --
--------------------------------------------------------------------------------

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
-- Binary instances                                                           --
--------------------------------------------------------------------------------

instance Binary LocalProcessId where
  put lpid = put (lpidUnique lpid) >> put (lpidCounter lpid)
  get      = LocalProcessId <$> get <*> get

instance Binary ProcessId where
  put pid = put (processNodeId pid) >> put (processLocalId pid)
  get     = ProcessId <$> get <*> get

instance Binary MonitorNotification where
  put (MonitorNotification ref pid reason) = put ref >> put pid >> put reason
  get = MonitorNotification <$> get <*> get <*> get

instance Binary NCMsg where
  put msg = put (ctrlMsgSender msg) >> put (ctrlMsgSignal msg)
  get     = NCMsg <$> get <*> get

instance Binary MonitorRef where
  put ref = put (monitorRefPid ref) >> put (monitorRefCounter ref)
  get     = MonitorRef <$> get <*> get

instance Binary ProcessSignal where
  put (Link pid)        = putWord8 0 >> put pid
  put (Unlink pid)      = putWord8 1 >> put pid
  put (Monitor pid ref) = putWord8 2 >> put pid >> put ref
  put (Unmonitor ref)   = putWord8 3 >> put ref 
  put (Died who reason) = putWord8 4 >> put who >> put reason
  put (Spawn proc ref)  = putWord8 5 >> put proc >> put ref
  get = do
    header <- getWord8
    case header of
      0 -> Link <$> get
      1 -> Unlink <$> get
      2 -> Monitor <$> get <*> get
      3 -> Unmonitor <$> get
      4 -> Died <$> get <*> get
      5 -> Spawn <$> get <*> get
      _ -> fail "ProcessSignal.get: invalid"

instance Binary DiedReason where
  put DiedNormal        = putWord8 0
  put (DiedException e) = putWord8 1 >> put e 
  put DiedDisconnect    = putWord8 2
  put DiedNodeDown      = putWord8 3
  put DiedNoProc        = putWord8 4
  get = do
    header <- getWord8
    case header of
      0 -> return DiedNormal
      1 -> DiedException <$> get
      2 -> return DiedDisconnect
      3 -> return DiedNodeDown
      4 -> return DiedNoProc
      _ -> fail "DiedReason.get: invalid"

instance Binary (Closure a) where
  put (Closure (Static label) env) = put label >> put env
  get = Closure <$> (Static <$> get) <*> get 

instance Binary DidSpawn where
  put (DidSpawn ref pid) = put ref >> put pid
  get = DidSpawn <$> get <*> get

instance Binary ChannelId where
  put cid = put (channelProcessId cid) >> put (channelLocalId cid)
  get = ChannelId <$> get <*> get 

instance Binary Identifier where
  put (ProcessIdentifier pid) = putWord8 0 >> put pid
  put (NodeIdentifier nid)    = putWord8 1 >> put nid
  put (ChannelIdentifier cid) = putWord8 2 >> put cid
  get = do
    header <- getWord8 
    case header of
      0 -> ProcessIdentifier <$> get
      1 -> NodeIdentifier <$> get
      2 -> ChannelIdentifier <$> get
      _ -> fail "Identifier.get: invalid"

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

channelCounter :: Accessor LocalProcessState LocalChannelId
channelCounter = accessor _channelCounter (\cnt st -> st { _channelCounter = cnt })

typedChannels :: Accessor LocalProcessState (Map LocalChannelId TypedChannel)
typedChannels = accessor _typedChannels (\cs st -> st { _typedChannels = cs })

typedChannelWithId :: LocalChannelId -> Accessor LocalProcessState (Maybe TypedChannel)
typedChannelWithId cid = typedChannels >>> DAC.mapMaybe cid

--------------------------------------------------------------------------------
-- MessageT monad                                                             --
--------------------------------------------------------------------------------

newtype MessageT m a = MessageT { unMessageT :: StateT MessageState m a }
  deriving (Functor, Monad, MonadIO, MonadState MessageState)

data MessageState = MessageState { 
     messageLocalNode   :: LocalNode
  , _messageConnections :: Map Identifier NT.Connection 
  }

runMessageT :: Monad m => LocalNode -> MessageT m a -> m a
runMessageT localNode m = 
  evalStateT (unMessageT m) $ initMessageState localNode 

initMessageState :: LocalNode -> MessageState
initMessageState localNode = MessageState {
     messageLocalNode   = localNode 
  , _messageConnections = Map.empty
  }

