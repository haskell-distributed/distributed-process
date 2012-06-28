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
    -- * Local nodes and processes
  , LocalNode(..)
  , LocalNodeState(..)
  , LocalProcess(..)
  , LocalProcessState(..)
  , Process(..)
  , procMsg
    -- * Typed channels
  , LocalChannelId 
  , ChannelId(..)
  , TypedChannel(..)
  , SendPort(..)
  , ReceivePort(..)
    -- * Closures
  , StaticLabel(..)
  , Static(..) 
  , Closure(..)
  , CallReply(..)
  , RemoteTable(..)
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
  , remoteTableSenders
  , remoteTableLabel
  , remoteTableSender
  ) where

import Data.Map (Map)
import Data.Int (Int32)
import Data.Typeable (Typeable, TypeRep)
import Data.Binary (Binary(put, get), putWord8, getWord8)
import Data.ByteString.Lazy (ByteString)
import Data.Accessor (Accessor, accessor)
import qualified Data.Accessor.Container as DAC (mapMaybe)
import qualified Data.ByteString.Lazy as BSL (ByteString)
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
import Control.Distributed.Process.Serializable (Fingerprint, Serializable)
import Control.Distributed.Process.Internal.CQueue (CQueue)
import Control.Distributed.Process.Internal.Dynamic (Dynamic) 

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
  , _typedChannels  :: Map LocalChannelId TypedChannel 
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

type LocalChannelId = Int32

data ChannelId = ChannelId {
    channelProcessId :: ProcessId
  , channelLocalId   :: LocalChannelId
  }
  deriving (Show, Eq, Ord)

data TypedChannel = forall a. Serializable a => TypedChannel (TChan a)

-- | The send send of a typed channel (serializable)
newtype SendPort a = SendPort ChannelId deriving (Typeable, Binary)

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
  -- Special support for 'call'
  | Call
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
data Closure a = Closure (Static (ByteString -> a)) ByteString
  deriving (Typeable, Show)

-- | Used for the implementation of 'call'
newtype CallReply a = CallReply a
  deriving (Typeable, Binary)

-- | Used to fake 'static' (see paper)
data RemoteTable = RemoteTable {
    _remoteTableLabels  :: Map String Dynamic 
  , _remoteTableSenders :: Map TypeRep Dynamic
  }

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
  deriving (Typeable, Show)

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

instance Binary StaticLabel where
  put (UserStatic string) = putWord8 0 >> put string
  put Call         = putWord8 1
  put ClosureApply = putWord8 2
  put ClosureConst = putWord8 3
  put ClosureUnit  = putWord8 4
  put CpId         = putWord8 5
  put CpComp       = putWord8 6
  put CpFirst      = putWord8 7
  put CpSwap       = putWord8 8
  put CpCopy       = putWord8 9
  put CpLeft       = putWord8 10
  put CpMirror     = putWord8 11
  put CpUntag      = putWord8 12
  put CpApply      = putWord8 13
  get = do
    header <- getWord8
    case header of
      0  -> UserStatic <$> get
      1  -> return Call
      2  -> return ClosureApply
      3  -> return ClosureConst
      4  -> return ClosureUnit
      5  -> return CpId
      6  -> return CpComp 
      7  -> return CpFirst
      8  -> return CpSwap
      9  -> return CpCopy
      10 -> return CpLeft
      11 -> return CpMirror
      12 -> return CpUntag
      13 -> return CpApply
      _  -> fail "StaticLabel.get: invalid"

  

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

remoteTableLabels :: Accessor RemoteTable (Map String Dynamic)
remoteTableLabels = accessor _remoteTableLabels (\ls tbl -> tbl { _remoteTableLabels = ls })

remoteTableSenders :: Accessor RemoteTable (Map TypeRep Dynamic)
remoteTableSenders = accessor _remoteTableSenders (\es tbl -> tbl { _remoteTableSenders = es })

remoteTableLabel :: String -> Accessor RemoteTable (Maybe Dynamic)
remoteTableLabel label = remoteTableLabels >>> DAC.mapMaybe label

remoteTableSender :: TypeRep -> Accessor RemoteTable (Maybe Dynamic)
remoteTableSender typ = remoteTableSenders >>> DAC.mapMaybe typ

--------------------------------------------------------------------------------
-- MessageT monad                                                             --
--------------------------------------------------------------------------------

newtype MessageT m a = MessageT { unMessageT :: StateT MessageState m a }
  deriving (Functor, Monad, MonadIO, MonadState MessageState, Applicative)

data MessageState = MessageState { 
     messageLocalNode   :: LocalNode
  , _messageConnections :: Map Identifier NT.Connection 
  }
