-- | Cloud Haskell primitives
--
-- We define these in a separate module so that we don't have to rely on 
-- the closure combinators
module Control.Distributed.Process.Internal.Process.Primitives 
  ( -- * Basic messaging
    send 
  , expect
    -- * Channels
  , newChan
  , sendChan
  , receiveChan
  , mergePortsBiased
  , mergePortsRR
    -- * Advanced messaging
  , Match
  , receiveWait
  , receiveTimeout
  , match
  , matchIf
  , matchUnknown
    -- * Process management
  , spawn
  , terminate
  , ProcessTerminationException(..)
  , getSelfPid
  , getSelfNode
    -- * Monitoring and linking
  , link
  , unlink
  , monitor
  , unmonitor
    -- * Auxiliary API
  , catch
  , expectTimeout
  , spawnAsync
  , spawnLink
  , spawnMonitor
  ) where

import Prelude hiding (catch)
import Data.Binary (decode)
import Data.Typeable (Typeable,)
import Control.Monad.Reader (ask)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throw)
import qualified Control.Exception as Exception (catch)
import Control.Concurrent.MVar (modifyMVar)
import Control.Concurrent.Chan (writeChan)
import Control.Concurrent.STM 
  ( STM
  , atomically
  , orElse
  , newTChan
  , readTChan
  , newTVar
  , readTVar
  , writeTVar
  )
import Control.Distributed.Process.Internal.CQueue (dequeue, BlockSpec(..))
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
import Data.Accessor ((^.), (^:), (^=))
import Control.Distributed.Process.Internal.Types 
  ( NodeId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , Closure(..)
  , Message(..)
  , MonitorRef(..)
  , SpawnRef(..)
  , DidSpawn(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , monitorCounter 
  , spawnCounter
  , Closure(..)
  , SendPort(..)
  , ReceivePort(..)
  , channelCounter
  , typedChannelWithId
  , TypedChannel(..)
  , ChannelId(..)
  , Identifier(..)
  , procMsg
  )
import Control.Distributed.Process.Internal.MessageT 
  ( sendMessage
  , sendBinary
  , getLocalNode
  )  
import Control.Distributed.Process.Internal.Node (runLocalProcess)

--------------------------------------------------------------------------------
-- Basic messaging                                                            --
--------------------------------------------------------------------------------

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
-- This requires a lookup on every send. If we want to avoid that we need to
-- modify serializable to allow for stateful (IO) deserialization
send them msg = procMsg $ sendMessage (ProcessIdentifier them) msg 

-- | Wait for a message of a specific type
expect :: forall a. Serializable a => Process a
expect = receiveWait [match return] 

--------------------------------------------------------------------------------
-- Channels                                                                   --
--------------------------------------------------------------------------------

-- | Create a new typed channel
newChan :: Serializable a => Process (SendPort a, ReceivePort a)
newChan = do
  proc <- ask 
  liftIO . modifyMVar (processState proc) $ \st -> do
    chan <- liftIO . atomically $ newTChan
    let lcid  = st ^. channelCounter
        cid   = ChannelId { channelProcessId = processId proc
                          , channelLocalId   = lcid
                          }
        sport = SendPort cid 
        rport = ReceivePortSingle chan
        tch   = TypedChannel chan 
    return ( (channelCounter ^: (+ 1))
           . (typedChannelWithId lcid ^= Just tch)
           $ st
           , (sport, rport)
           )

-- | Send a message on a typed channel
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan (SendPort them) msg = procMsg $ sendBinary (ChannelIdentifier them) msg 

-- | Wait for a message on a typed channel
receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan = liftIO . atomically . receiveSTM 
  where
    receiveSTM :: ReceivePort a -> STM a
    receiveSTM (ReceivePortSingle c) = 
      readTChan c
    receiveSTM (ReceivePortBiased ps) =
      foldr1 orElse (map receiveSTM ps)
    receiveSTM (ReceivePortRR psVar) = do
      ps <- readTVar psVar
      a  <- foldr1 orElse (map receiveSTM ps)
      writeTVar psVar (rotate ps)
      return a

    rotate :: [a] -> [a]
    rotate []     = []
    rotate (x:xs) = xs ++ [x]

-- | Merge a list of typed channels.
-- 
-- The result port is left-biased: if there are messages available on more
-- than one port, the first available message is returned.
mergePortsBiased :: Serializable a => [ReceivePort a] -> Process (ReceivePort a)
mergePortsBiased = return . ReceivePortBiased 

-- | Like 'mergePortsBiased', but with a round-robin scheduler (rather than
-- left-biased)
mergePortsRR :: Serializable a => [ReceivePort a] -> Process (ReceivePort a)
mergePortsRR ps = liftIO . atomically $ ReceivePortRR <$> newTVar ps

--------------------------------------------------------------------------------
-- Advanced messaging                                                         -- 
--------------------------------------------------------------------------------

-- | Opaque type used in 'receiveWait' and 'receiveTimeout'
newtype Match b = Match { unMatch :: Message -> Maybe (Process b) }

-- | Test the matches in order against each message in the queue
receiveWait :: [Match b] -> Process b
receiveWait ms = do
  queue <- processQueue <$> ask
  Just proc <- liftIO $ dequeue queue Blocking (map unMatch ms)
  proc

-- | Like 'receiveWait' but with a timeout.
-- 
-- If the timeout is zero do a non-blocking check for matching messages. A
-- non-zero timeout is applied only when waiting for incoming messages (that is,
-- /after/ we have checked the messages that are already in the mailbox).
receiveTimeout :: Int -> [Match b] -> Process (Maybe b)
receiveTimeout t ms = do
  queue <- processQueue <$> ask
  let blockSpec = if t == 0 then NonBlocking else Timeout t
  mProc <- liftIO $ dequeue queue blockSpec (map unMatch ms)
  case mProc of
    Nothing   -> return Nothing
    Just proc -> Just <$> proc

-- | Match against any message of the right type
match :: forall a b. Serializable a => (a -> Process b) -> Match b
match = matchIf (const True) 

-- | Match against any message of the right type that satisfies a predicate
matchIf :: forall a b. Serializable a => (a -> Bool) -> (a -> Process b) -> Match b
matchIf c p = Match $ \msg -> 
  let decoded :: a
      decoded = decode . messageEncoding $ msg in
  if messageFingerprint msg == fingerprint (undefined :: a) && c decoded
    then Just $ p decoded 
    else Nothing

-- | Remove any message from the queue
matchUnknown :: Process b -> Match b
matchUnknown = Match . const . Just

--------------------------------------------------------------------------------
-- Process management                                                         --
--------------------------------------------------------------------------------

-- | Spawn a process
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid proc = do
  ref <- spawnAsync nid proc 
  receiveWait [ matchIf (\(DidSpawn ref' _) -> ref == ref')
                        (\(DidSpawn _ pid) -> return pid)
              ]

-- | Thrown by 'terminate'
data ProcessTerminationException = ProcessTerminationException
  deriving (Show, Typeable)

instance Exception ProcessTerminationException

-- | Terminate (throws a ProcessTerminationException)
terminate :: Process a
terminate = liftIO $ throw ProcessTerminationException

-- | Our own process ID
getSelfPid :: Process ProcessId
getSelfPid = processId <$> ask 

-- | Get the node ID of our local node
getSelfNode :: Process NodeId
getSelfNode = localNodeId <$> procMsg getLocalNode

--------------------------------------------------------------------------------
-- Monitoring and linking                                                     --
--------------------------------------------------------------------------------

-- | Link to a remote process (asynchronous)
--
-- Note that 'link' provides unidirectional linking (see 'spawnSupervised').
link :: ProcessId -> Process ()
link = sendCtrlMsg Nothing . Link

-- | Remove a link (asynchronous)
unlink :: ProcessId -> Process ()
unlink = sendCtrlMsg Nothing . Unlink

-- | Monitor another process (asynchronous)
monitor :: ProcessId -> Process MonitorRef 
monitor them = do
  monitorRef <- getMonitorRefFor them
  sendCtrlMsg Nothing $ Monitor them monitorRef
  return monitorRef

-- | Remove a monitor (asynchronous)
unmonitor :: MonitorRef -> Process ()
unmonitor = sendCtrlMsg Nothing . Unmonitor

--------------------------------------------------------------------------------
-- Auxiliary API                                                              --
--------------------------------------------------------------------------------

-- | Catch exceptions within a process
catch :: Exception e => Process a -> (e -> Process a) -> Process a
catch p h = do
  node  <- procMsg getLocalNode
  lproc <- ask
  let run :: Process a -> IO a
      run proc = runLocalProcess node proc lproc 
  liftIO $ Exception.catch (run p) (run . h) 

-- | Like 'expect' but with a timeout
expectTimeout :: forall a. Serializable a => Int -> Process (Maybe a)
expectTimeout timeout = receiveTimeout timeout [match return] 

-- | Asynchronous version of 'spawn'
-- 
-- ('spawn' is defined in terms of 'spawnAsync' and 'expect')
spawnAsync :: NodeId -> Closure (Process ()) -> Process SpawnRef
spawnAsync nid proc = do
  spawnRef <- getSpawnRef
  sendCtrlMsg (Just nid) $ Spawn proc spawnRef
  return spawnRef

-- | Spawn a process and link to it
--
-- Note that this is just the sequential composition of 'spawn' and 'link'. 
-- (The "Unified" semantics that underlies Cloud Haskell does not even support
-- a synchronous link operation)
spawnLink :: NodeId -> Closure (Process ()) -> Process ProcessId
spawnLink nid proc = do
  pid <- spawn nid proc
  link pid
  return pid

-- | Like 'spawnLink', but monitor the spawned process
spawnMonitor :: NodeId -> Closure (Process ()) -> Process (ProcessId, MonitorRef)
spawnMonitor nid proc = do
  pid <- spawn nid proc
  ref <- monitor pid
  return (pid, ref)

--------------------------------------------------------------------------------
-- Auxiliary functions                                                        --
--------------------------------------------------------------------------------

getMonitorRefFor :: ProcessId -> Process MonitorRef
getMonitorRefFor pid = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do 
    let counter = st ^. monitorCounter 
    return ( monitorCounter ^: (+ 1) $ st
           , MonitorRef pid counter 
           )

getSpawnRef :: Process SpawnRef
getSpawnRef = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do
    let counter = st ^. spawnCounter
    return ( spawnCounter ^: (+ 1) $ st
           , SpawnRef counter
           )

-- Send a control message
sendCtrlMsg :: Maybe NodeId  -- ^ Nothing for the local node
            -> ProcessSignal -- ^ Message to send 
            -> Process ()
sendCtrlMsg mNid signal = do            
  us <- getSelfPid
  let msg = NCMsg { ctrlMsgSender = ProcessIdentifier us
                  , ctrlMsgSignal = signal
                  }
  case mNid of
    Nothing -> do
      ctrlChan <- localCtrlChan <$> procMsg getLocalNode 
      liftIO $ writeChan ctrlChan msg 
    Just nid ->
      procMsg $ sendBinary (NodeIdentifier nid) msg
