-- | Cloud Haskell primitives
--
-- We define these in a separate module so that we don't have to rely on 
-- the closure combinators
module Control.Distributed.Process.Internal.Primitives 
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
  , terminate
  , ProcessTerminationException(..)
  , getSelfPid
  , getSelfNode
    -- * Monitoring and linking
  , link
  , unlink
  , monitor
  , unmonitor
    -- * Logging
  , say
    -- * Registry
  , register
  , unregister
  , whereis
  , nsend
  , registerRemote
  , unregisterRemote
  , whereisRemote
  , whereisRemoteAsync
  , nsendRemote
    -- * Closures
  , unClosure
    -- * Exception handling
  , catch
  , mask
  , onException
  , bracket
  , bracket_
  , finally
    -- * Auxiliary API
  , expectTimeout
  , spawnAsync
  , linkNode
  , linkPort
  , unlinkNode
  , unlinkPort
  , monitorNode
  , monitorPort
    -- * Reconnecting
  , reconnect
  , reconnectNode
  , reconnectPort
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Data.Binary (decode)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime)
import System.Locale (defaultTimeLocale)
import Control.Monad.Reader (ask)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException)
import qualified Control.Exception as Ex (catch, mask)
import Control.Distributed.Process.Internal.StrictMVar (modifyMVar)
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
import Control.Distributed.Static (Closure)
import Data.Rank1Typeable (Typeable)
import qualified Control.Distributed.Static as Static (unclosure)
import Control.Distributed.Process.Internal.Types 
  ( NodeId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , Message(..)
  , MonitorRef(..)
  , SpawnRef(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , monitorCounter 
  , spawnCounter
  , SendPort(..)
  , ReceivePort(..)
  , channelCounter
  , typedChannelWithId
  , TypedChannel(..)
  , SendPortId(..)
  , Identifier(..)
  , DidUnmonitor(..)
  , DidUnlinkProcess(..)
  , DidUnlinkNode(..)
  , DidUnlinkPort(..)
  , WhereIsReply(..)
  , createMessage
  , runLocalProcess
  )
import Control.Distributed.Process.Internal.Node (sendMessage, sendBinary) 

--------------------------------------------------------------------------------
-- Basic messaging                                                            --
--------------------------------------------------------------------------------

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
-- This requires a lookup on every send. If we want to avoid that we need to
-- modify serializable to allow for stateful (IO) deserialization
send them msg = do
  proc <- ask 
  liftIO $ sendMessage (processNode proc) 
                       (ProcessIdentifier (processId proc)) 
                       (ProcessIdentifier them)
                       msg

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
        cid   = SendPortId { sendPortProcessId = processId proc
                           , sendPortLocalId   = lcid
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
sendChan (SendPort cid) msg = do
  proc <- ask
  liftIO $ sendBinary (processNode proc)
                      (ProcessIdentifier (processId proc))
                      (SendPortIdentifier cid) 
                      msg 

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

-- | Thrown by 'terminate'
data ProcessTerminationException = ProcessTerminationException
  deriving (Show, Typeable)

instance Exception ProcessTerminationException

-- | Terminate (throws a ProcessTerminationException)
terminate :: Process a
terminate = liftIO $ throwIO ProcessTerminationException

-- | Our own process ID
getSelfPid :: Process ProcessId
getSelfPid = processId <$> ask 

-- | Get the node ID of our local node
getSelfNode :: Process NodeId
getSelfNode = localNodeId . processNode <$> ask 

--------------------------------------------------------------------------------
-- Monitoring and linking                                                     --
--------------------------------------------------------------------------------

-- | Link to a remote process (asynchronous)
--
-- Note that 'link' provides unidirectional linking (see 'spawnSupervised').
-- Linking makes no distinction between normal and abnormal termination of
-- the remote process.
link :: ProcessId -> Process ()
link = sendCtrlMsg Nothing . Link . ProcessIdentifier

-- | Monitor another process (asynchronous)
monitor :: ProcessId -> Process MonitorRef 
monitor = monitor' . ProcessIdentifier 

-- | Remove a link (synchronous)
unlink :: ProcessId -> Process ()
unlink pid = do
  unlinkAsync pid
  receiveWait [ matchIf (\(DidUnlinkProcess pid') -> pid' == pid) 
                        (\_ -> return ()) 
              ]

-- | Remove a node link (synchronous)
unlinkNode :: NodeId -> Process ()
unlinkNode nid = do
  unlinkNodeAsync nid
  receiveWait [ matchIf (\(DidUnlinkNode nid') -> nid' == nid)
                        (\_ -> return ())
              ]

-- | Remove a channel (send port) link (synchronous)
unlinkPort :: SendPort a -> Process ()
unlinkPort sport = do
  unlinkPortAsync sport
  receiveWait [ matchIf (\(DidUnlinkPort cid) -> cid == sendPortId sport)
                        (\_ -> return ())
              ]

-- | Remove a monitor (synchronous)
unmonitor :: MonitorRef -> Process ()
unmonitor ref = do
  unmonitorAsync ref
  receiveWait [ matchIf (\(DidUnmonitor ref') -> ref' == ref)
                        (\_ -> return ())
              ]

--------------------------------------------------------------------------------
-- Exception handling                                                         --
--------------------------------------------------------------------------------

-- | Lift 'Control.Exception.catch'
catch :: Exception e => Process a -> (e -> Process a) -> Process a
catch p h = do
  lproc <- ask
  liftIO $ Ex.catch (runLocalProcess lproc p) (runLocalProcess lproc . h) 

-- | Lift 'Control.Exception.mask' 
mask :: ((forall a. Process a -> Process a) -> Process b) -> Process b
mask p = do 
    lproc <- ask
    liftIO $ Ex.mask $ \restore ->
      runLocalProcess lproc (p (liftRestore lproc restore))
  where
    liftRestore :: LocalProcess -> (forall a. IO a -> IO a) -> (forall a. Process a -> Process a)
    liftRestore lproc restoreIO = liftIO . restoreIO . runLocalProcess lproc

-- | Lift 'Control.Exception.onException'
onException :: Process a -> Process b -> Process a
onException p what = p `catch` \e -> do _ <- what
                                        liftIO $ throwIO (e :: SomeException)

-- | Lift 'Control.Exception.bracket'
bracket :: Process a -> (a -> Process b) -> (a -> Process c) -> Process c
bracket before after thing =
  mask $ \restore -> do
    a <- before
    r <- restore (thing a) `onException` after a
    _ <- after a
    return r

-- | Lift 'Control.Exception.bracket_'
bracket_ :: Process a -> Process b -> Process c -> Process c
bracket_ before after thing = bracket before (const after) (const thing)

-- | Lift 'Control.Exception.finally'
finally :: Process a -> Process b -> Process a
finally a sequel = bracket_ (return ()) sequel a 

--------------------------------------------------------------------------------
-- Auxiliary API                                                              --
--------------------------------------------------------------------------------

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

-- | Monitor a node
monitorNode :: NodeId -> Process MonitorRef
monitorNode = 
  monitor' . NodeIdentifier

-- | Monitor a typed channel
monitorPort :: forall a. Serializable a => SendPort a -> Process MonitorRef
monitorPort (SendPort cid) = 
  monitor' (SendPortIdentifier cid) 

-- | Remove a monitor (asynchronous)
unmonitorAsync :: MonitorRef -> Process ()
unmonitorAsync = 
  sendCtrlMsg Nothing . Unmonitor

-- | Link to a node
linkNode :: NodeId -> Process ()
linkNode = link' . NodeIdentifier 

-- | Link to a channel (send port)
linkPort :: SendPort a -> Process ()
linkPort (SendPort cid) = 
  link' (SendPortIdentifier cid)

-- | Remove a process link (asynchronous)
unlinkAsync :: ProcessId -> Process ()
unlinkAsync = 
  sendCtrlMsg Nothing . Unlink . ProcessIdentifier

-- | Remove a node link (asynchronous)
unlinkNodeAsync :: NodeId -> Process ()
unlinkNodeAsync = 
  sendCtrlMsg Nothing . Unlink . NodeIdentifier

-- | Remove a channel (send port) link (asynchronous)
unlinkPortAsync :: SendPort a -> Process ()
unlinkPortAsync (SendPort cid) = 
  sendCtrlMsg Nothing . Unlink $ SendPortIdentifier cid

--------------------------------------------------------------------------------
-- Logging                                                                    --
--------------------------------------------------------------------------------

-- | Log a string
--
-- @say message@ sends a message (time, pid of the current process, message)
-- to the process registered as 'logger'.  By default, this process simply
-- sends the string to 'stderr'. Individual Cloud Haskell backends might
-- replace this with a different logger process, however.
say :: String -> Process ()
say string = do
  now <- liftIO getCurrentTime
  us  <- getSelfPid
  nsend "logger" (formatTime defaultTimeLocale "%c" now, us, string)

--------------------------------------------------------------------------------
-- Registry                                                                   --
--------------------------------------------------------------------------------

-- | Register a process with the local registry (asynchronous).
--
-- The process to be registered does not have to be local itself.
register :: String -> ProcessId -> Process ()
register label pid = 
  sendCtrlMsg Nothing (Register label (Just pid))

-- | Register a process with a remote registry (asynchronous).
--
-- The process to be registered does not have to live on the same remote node.
registerRemote :: NodeId -> String -> ProcessId -> Process ()
registerRemote nid label pid = 
  sendCtrlMsg (Just nid) (Register label (Just pid)) 

-- | Remove a process from the local registry (asynchronous).
unregister :: String -> Process ()
unregister label = 
  sendCtrlMsg Nothing (Register label Nothing)

-- | Remove a process from a remote registry (asynchronous).
unregisterRemote :: NodeId -> String -> Process ()
unregisterRemote nid label =
  sendCtrlMsg (Just nid) (Register label Nothing)

-- | Query the local process registry (synchronous).
whereis :: String -> Process (Maybe ProcessId)
whereis label = do
  sendCtrlMsg Nothing (WhereIs label)
  receiveWait [ matchIf (\(WhereIsReply label' _) -> label == label')
                        (\(WhereIsReply _ mPid) -> return mPid)
              ]

-- | Query a remote process registry (synchronous)
whereisRemote :: NodeId -> String -> Process (Maybe ProcessId)
whereisRemote nid label = do
  whereisRemoteAsync nid label
  receiveWait [ matchIf (\(WhereIsReply label' _) -> label == label')
                        (\(WhereIsReply _ mPid) -> return mPid)
              ]

-- | Query a remote process registry (asynchronous)
--
-- Reply will come in the form of a 'WhereIsReply' message
whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync nid label = 
  sendCtrlMsg (Just nid) (WhereIs label)

-- | Named send to a process in the local registry (asynchronous) 
nsend :: Serializable a => String -> a -> Process ()
nsend label msg = 
  sendCtrlMsg Nothing (NamedSend label (createMessage msg))

-- | Named send to a process in a remote registry (asynchronous)
nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote nid label msg = 
  sendCtrlMsg (Just nid) (NamedSend label (createMessage msg))

--------------------------------------------------------------------------------
-- Closures                                                                   --
--------------------------------------------------------------------------------

-- | Deserialize a closure
unClosure :: forall a. Typeable a => Closure a -> Process a
unClosure closure = do
  rtable <- remoteTable . processNode <$> ask 
  case Static.unclosure rtable closure of
    Left err -> fail $ "Could not resolve closure: " ++ err 
    Right x  -> return x

--------------------------------------------------------------------------------
-- Reconnecting                                                               --
--------------------------------------------------------------------------------

-- | Cloud Haskell provides the illusion of connection-less, reliable, ordered
-- message passing. However, when network connections get disrupted this
-- illusion cannot always be maintained. Once a network connection breaks (even
-- temporarily) no further communication on that connection will be possible.
-- For example, if process A sends a message to process B, and A is then 
-- notified (by monitor notification) that it got disconnected from B, A will
-- not be able to send any further messages to B, /unless/ A explicitly 
-- indicates that it is acceptable to attempt to reconnect to B using the
-- Cloud Haskell 'reconnect' primitive. 
--
-- Importantly, when A calls 'reconnect' it acknowledges that some messages to
-- B might have been lost. For instance, if A sends messages m1 and m2 to B,
-- then receives a monitor notification that its connection to B has been lost,
-- calls 'reconnect' and then sends m3, it is possible that B will receive m1
-- and m3 but not m2.
--
-- Note that 'reconnect' does not mean /reconnect now/ but rather /it is okay
-- to attempt to reconnect on the next send/. In particular, if no further
-- communication attempts are made to B then A can use reconnect to clean up
-- its connection to B.
reconnect :: ProcessId -> Process ()
reconnect = 
  sendCtrlMsg Nothing . Reconnect . ProcessIdentifier 

-- | Reconnect to a node. See 'reconnect' for more information.
reconnectNode :: NodeId -> Process ()
reconnectNode = 
  sendCtrlMsg Nothing . Reconnect . NodeIdentifier 

-- | Reconnect to a sendport. See 'reconnect' for more information.
reconnectPort :: SendPort a -> Process ()
reconnectPort = 
  sendCtrlMsg Nothing . Reconnect . SendPortIdentifier . sendPortId

--------------------------------------------------------------------------------
-- Auxiliary functions                                                        --
--------------------------------------------------------------------------------

getMonitorRefFor :: Identifier -> Process MonitorRef
getMonitorRefFor ident = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do 
    let counter = st ^. monitorCounter 
    return ( monitorCounter ^: (+ 1) $ st
           , MonitorRef ident counter 
           )

getSpawnRef :: Process SpawnRef
getSpawnRef = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do
    let counter = st ^. spawnCounter
    return ( spawnCounter ^: (+ 1) $ st
           , SpawnRef counter
           )

-- | Monitor a process/node/channel
monitor' :: Identifier -> Process MonitorRef
monitor' ident = do
  monitorRef <- getMonitorRefFor ident 
  sendCtrlMsg Nothing $ Monitor monitorRef
  return monitorRef

-- | Link to a process/node/channel
link' :: Identifier -> Process ()
link' = sendCtrlMsg Nothing . Link

-- Send a control message
sendCtrlMsg :: Maybe NodeId  -- ^ Nothing for the local node
            -> ProcessSignal -- ^ Message to send 
            -> Process ()
sendCtrlMsg mNid signal = do            
  proc <- ask
  let msg = NCMsg { ctrlMsgSender = ProcessIdentifier (processId proc) 
                  , ctrlMsgSignal = signal
                  }
  case mNid of
    Nothing -> do
      ctrlChan <- localCtrlChan . processNode <$> ask 
      liftIO $ writeChan ctrlChan msg 
    Just nid ->
      liftIO $ sendBinary (processNode proc)
                          (ProcessIdentifier (processId proc))
                          (NodeIdentifier nid)
                          msg
