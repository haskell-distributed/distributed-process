-- | [Cloud Haskell]
-- 
-- This is an implementation of Cloud Haskell, as described in 
-- /Towards Haskell in the Cloud/ by Jeff Epstein, Andrew Black, and Simon
-- Peyton Jones
-- (<http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/>),
-- although some of the details are different. The precise message passing
-- semantics are based on /A unified semantics for future Erlang/ by	Hans
-- Svensson, Lars-Åke Fredlund and Clara Benac Earle.
module Control.Distributed.Process 
  ( -- * Basic cloud Haskell API
    ProcessId
  , NodeId
  , Process
  , expect
  , send 
  , getSelfPid
  , RemoteCallMetaData
  , initRemoteCallMetaData
    -- * Matching messages
  , Match
  , match
  , matchIf
  , matchUnknown
  , receiveWait
  , receiveTimeout
    -- * Monitoring and linking
  , link
  , unlink
  , monitor
  , unmonitor
  , LinkException(..)
  , MonitorRef -- opaque
  , MonitorNotification(..)
  , DiedReason(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
    -- * Initialization
  , newLocalNode
  , forkProcess
  , runProcess
    -- * Auxiliary API
  , closeLocalNode
  , catch
  , expectTimeout
  ) where

import Prelude hiding (catch)
import System.IO (fixIO)
import qualified Data.ByteString as BSS (ByteString)
import qualified Data.ByteString.Lazy as BSL (fromChunks)
import Data.Binary (decode)
import Data.Map (Map)
import qualified Data.Map as Map (empty, lookup, insert, delete)
import qualified Data.List as List (delete)
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert, delete, member)
import Data.Foldable (forM_)
import Data.Typeable (Typeable)
import Control.Monad (void)
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException)
import qualified Control.Exception as Exception (catch)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar ( newMVar 
                               , withMVar
                               , modifyMVar
                               , modifyMVar_
                               , newEmptyMVar
                               , putMVar
                               , takeMVar
                               )
import Control.Concurrent.Chan (newChan, writeChan)
import Control.Distributed.Process.Internal.CQueue (enqueue, dequeue, newCQueue)
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
import qualified Network.Transport as NT ( Transport
                                         , EndPoint
                                         , Connection
                                         , Reliability(ReliableOrdered)
                                         , defaultConnectHints
                                         , send
                                         , connect
                                         , close
                                         , newEndPoint
                                         , receive
                                         , Event(..)
                                         , EventErrorCode(..)
                                         , TransportError(..)
                                         , address
                                         , closeEndPoint
                                         , ConnectionId
                                         )
import Data.Accessor ((^.), (^=), (^:))
import System.Random (randomIO)
import Control.Distributed.Process.Internal.NodeController (runNodeController)
import Control.Distributed.Process.Internal ( RemoteCallMetaData
                                            , initRemoteCallMetaData
                                            , NodeId(..)
                                            , LocalProcessId(..)
                                            , ProcessId(..)
                                            , LocalNode(..)
                                            , LocalNodeState(..)
                                            , LocalProcess(..)
                                            , LocalProcessState(..)
                                            , Message(..)
                                            , MonitorRef(..)
                                            , MonitorNotification(..)
                                            , LinkException(..)
                                            , DidUnmonitor(..)
                                            , DidUnlink(..)
                                            , DiedReason(..)
                                            , NCMsg(..)
                                            , ProcessSignal(..)
                                            , createMessage
                                            , messageToPayload
                                            , payloadToMessage
                                            , payloadToId
                                            , idToPayload
                                            , localPidCounter
                                            , localPidUnique
                                            , localProcessWithId
                                            , localMonitorCounter
                                            , connectionTo
                                            )

-- INTERNAL NOTES
-- 
-- 1.  'send' never fails. If you want to know that the remote process received
--     your message, you will need to send an explicit acknowledgement. If you
--     want to know when the remote process failed, you will need to monitor
--     that remote process.
--
-- 2.  'send' may block (when the system TCP buffers are full, while we are
--     trying to establish a connection to the remote endpoint, etc.) but its
--     return does not imply that the remote process received the message (much
--     less processed it)
--
-- 3.  Message delivery is reliable and ordered. That means that if process A
--     sends messages m1, m2, m3 to process B, B will either arrive all three
--     messages in order (m1, m2, m3) or a prefix thereof; messages will not be
--     'missing' (m1, m3) or reordered (m1, m3, m2)
--
-- In order to guarantee (3), we stipulate that
--
-- 3a. We do not garbage collect connections because Network.Transport provides
--     ordering guarantees only *per connection*.
--
-- 3b. Once a connection breaks, we have no way of knowing which messages
--     arrived and which did not; hence, once a connection fails, we assume the
--     remote process to be forever unreachable. Otherwise we might sent m1 and
--     m2, get notified of the broken connection, reconnect, send m3, but only
--     m1 and m3 arrive.
--
-- 3c. As a consequence of (3b) we should not reuse PIDs. If a process dies,
--     we consider it forever unreachable. Hence, new processes should get new
--     IDs or they too would be considered unreachable.
--
-- Main reference for Cloud Haskell is
--
-- [1] "Towards Haskell in the Cloud", Jeff Epstein, Andrew Black and Simon
--     Peyton-Jones.
--       http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
--
-- The precise semantics for message passing is based on
-- 
-- [2] "A Unified Semantics for Future Erlang", Hans Svensson, Lars-Ake Fredlund
--     and Clara Benac Earle (not freely available online, unfortunately)
--
-- Some pointers to related documentation about Erlang, for comparison and
-- inspiration: 
--
-- [3] "Programming Distributed Erlang Applications: Pitfalls and Recipes",
--     Hans Svensson and Lars-Ake Fredlund 
--       http://man.lupaworld.com/content/develop/p37-svensson.pdf
-- [4] The Erlang manual, sections "Message Sending" and "Send" 
--       http://www.erlang.org/doc/reference_manual/processes.html#id82409
--       http://www.erlang.org/doc/reference_manual/expressions.html#send
-- [5] Questions "Is the order of message reception guaranteed?" and
--     "If I send a message, is it guaranteed to reach the receiver?" of
--     the Erlang FAQ
--       http://www.erlang.org/faq/academic.html
-- [6] "Delivery of Messages", post on erlang-questions
--       http://erlang.org/pipermail/erlang-questions/2012-February/064767.html

--------------------------------------------------------------------------------
-- Basic Cloud Haskell API                                                    --
--------------------------------------------------------------------------------

-- | The Cloud Haskell 'Process' type
newtype Process a = Process { unProcess :: ReaderT LocalProcess IO a }
  deriving (Functor, Monad, MonadIO, MonadReader LocalProcess, Typeable)

-- | Wait for a message of a specific type
expect :: forall a. Serializable a => Process a
expect = receiveWait [match return] 

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
send them msg = do
  -- This requires a lookup on every send. If we want to avoid that we need to
  -- modify serializable to allow for stateful (IO) deserialization
  mConn <- getConnectionTo them 
  forM_ mConn $ \conn -> sendMessage them conn (createMessage msg)

-- | Our own process ID
getSelfPid :: Process ProcessId
getSelfPid = processId <$> ask 

-- | Monitor another process
monitor :: ProcessId -> Process MonitorRef 
monitor them = do
  monitorRef <- getMonitorRefFor them
  postCtrlMsg $ Monitor them monitorRef
  return monitorRef

-- | Link to a remote process
link :: ProcessId -> Process ()
link = postCtrlMsg . Link

-- | Remove a monitor
unmonitor :: MonitorRef -> Process ()
unmonitor = postCtrlMsg . Unmonitor

-- | Remove a link
unlink :: ProcessId -> Process ()
unlink = postCtrlMsg . Unlink

--------------------------------------------------------------------------------
-- Matching                                                                   --
--------------------------------------------------------------------------------

-- | Opaque type used in 'receiveWait' and 'receiveTimeout'
newtype Match b = Match { unMatch :: Message -> Maybe (Process b) }

-- | Match against any message of the right type
match :: forall a b. Serializable a => (a -> Process b) -> Match b
match = matchIf (const True) 

-- | Match against any message of the right type that satisfies a predicate
matchIf :: forall a b. Serializable a => (a -> Bool) -> (a -> Process b) -> Match b
matchIf c p = Match $ \msg -> 
  let decoded :: a
      decoded = decode . messageEncoding $ msg in
  if messageFingerprint msg == fingerprint (undefined :: a) && c decoded
    then Just . p . decode . messageEncoding $ msg
    else Nothing

-- | Remove any message from the queue
matchUnknown :: Process b -> Match b
matchUnknown = Match . const . Just

-- | Test the matches in order against each message in the queue
receiveWait :: [Match b] -> Process b
receiveWait ms = do
  queue <- processQueue <$> ask
  Just proc <- liftIO $ dequeue queue Nothing (map unMatch ms)
  proc

-- | Like 'receiveWait' but with a timeout
receiveTimeout :: Int -> [Match b] -> Process (Maybe b)
receiveTimeout t ms = do
  queue <- processQueue <$> ask
  mProc <- liftIO $ dequeue queue (Just t) (map unMatch ms)
  case mProc of
    Nothing   -> return Nothing
    Just proc -> Just <$> proc

--------------------------------------------------------------------------------
-- Auxiliary API                                                              --
--------------------------------------------------------------------------------

-- | Force-close a local node
--
-- TODO: for now we just close the associated endpoint
closeLocalNode :: LocalNode -> IO ()
closeLocalNode node = 
  NT.closeEndPoint (localEndPoint node)

-- | Catch exceptions within a process
catch :: Exception e => Process a -> (e -> Process a) -> Process a
catch p h = do
  run <- runLocalProcess <$> ask
  liftIO $ Exception.catch (run p) (run . h) 

-- | Like 'expect' but with a timeout
expectTimeout :: forall a. Serializable a => Int -> Process (Maybe a)
expectTimeout timeout = receiveTimeout timeout [match return] 

--------------------------------------------------------------------------------
-- Initialization                                                             --
--------------------------------------------------------------------------------

-- | Initialize a new local node. 
-- 
-- Note that proper Cloud Haskell initialization and configuration is still 
-- to do.
newLocalNode :: NT.Transport -> RemoteCallMetaData -> IO LocalNode
newLocalNode transport metaData = do
  mEndPoint <- NT.newEndPoint transport
  case mEndPoint of
    Left ex -> throwIO ex
    Right endPoint -> do
      unq <- randomIO
      state <- newMVar LocalNodeState 
        { _localProcesses      = Map.empty
        , _localPidCounter     = 0 
        , _localPidUnique      = unq 
        , _localMonitorCounter = 0
        }
      ctrlChan <- newChan
      let node = LocalNode { localNodeId   = NodeId $ NT.address endPoint
                           , localEndPoint = endPoint
                           , localState    = state
                           , localCtrlChan = ctrlChan
                           , localMetaData = metaData
                           }
      void . forkIO $ runNodeController node 
      void . forkIO $ handleIncomingMessages node
      return node

-- | Run a process on a local node and wait for it to finish
runProcess :: LocalNode -> Process () -> IO ()
runProcess node proc = do
  done <- newEmptyMVar
  void $ forkProcess node (proc >> liftIO (putMVar done ()))
  takeMVar done

-- | Spawn a new process on a local node
forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess node proc = modifyMVar (localState node) $ \st -> do
  let lpid  = LocalProcessId { lpidCounter = st ^. localPidCounter
                             , lpidUnique  = st ^. localPidUnique
                             }
  let pid   = ProcessId { processNodeId  = localNodeId node 
                        , processLocalId = lpid
                        }
  pst <- newMVar LocalProcessState { _connections = Map.empty
                                   }
  queue <- newCQueue
  (_, lproc) <- fixIO $ \ ~(tid, _) -> do
    let lproc = LocalProcess { processQueue  = queue
                             , processNode   = node
                             , processId     = pid
                             , processState  = pst 
                             , processThread = tid
                             }
    tid' <- forkIO $ do
      reason <- Exception.catch 
        (runLocalProcess lproc proc >> return DiedNormal)
        (return . DiedException . (show :: SomeException -> String))
      -- [Unified: Table 4, rules termination and exiting]
      modifyMVar_ (localState node) $ 
        return . (localProcessWithId lpid ^= Nothing)
      writeChan (localCtrlChan node) NCMsg 
        { ctrlMsgSender = Left pid 
        , ctrlMsgSignal = Died (Left pid) reason 
        }
    return (tid', lproc)

  -- TODO: if the counter overflows we should pick a new unique                           
  return ( (localProcessWithId lpid ^= Just lproc)
         . (localPidCounter ^: (+ 1))
         $ st
         , pid 
         )
   
handleIncomingMessages :: LocalNode -> IO ()
handleIncomingMessages node = go [] Map.empty Set.empty
  where
    go :: [NT.ConnectionId] -- ^ Connections whose purpose we don't yet know 
       -> Map NT.ConnectionId LocalProcess -- ^ Connections to local processes
       -> Set NT.ConnectionId              -- ^ Connections to our controller
       -> IO () 
    go uninitConns procConns ctrlConns = do
      event <- NT.receive endpoint
      case event of
        NT.ConnectionOpened cid _rel _theirAddr ->
          go (cid : uninitConns) procConns ctrlConns 
        NT.Received cid payload -> 
          case Map.lookup cid procConns of
            Just proc -> do
              let msg = payloadToMessage payload
              enqueue (processQueue proc) msg
              go uninitConns procConns ctrlConns 
            Nothing | cid `Set.member` ctrlConns ->  do
              writeChan ctrlChan (decode . BSL.fromChunks $ payload)
              go uninitConns procConns ctrlConns 
            Nothing | cid `elem` uninitConns ->
              case payloadToId payload of
                Just lpid -> do
                  mProc <- withMVar state $ return . (^. localProcessWithId lpid) 
                  case mProc of
                    Just proc -> 
                      go (List.delete cid uninitConns) 
                         (Map.insert cid proc procConns)
                         ctrlConns
                    Nothing ->
                      fail "handleIncomingMessages: TODO 1" 
                Nothing ->
                  go (List.delete cid uninitConns)
                     procConns
                     (Set.insert cid ctrlConns)
            _ -> 
              fail "handleIncomingMessages: TODO 2" 
        NT.ConnectionClosed cid -> 
          go (List.delete cid uninitConns) 
             (Map.delete cid procConns)
             (Set.delete cid ctrlConns)
        NT.ErrorEvent (NT.TransportError (NT.EventConnectionLost (Just theirAddr) _) _) -> do 
          -- [Unified table 9, rule node_disconnect]
          let nid = Right $ NodeId theirAddr
          writeChan ctrlChan NCMsg 
            { ctrlMsgSender = nid
            , ctrlMsgSignal = Died nid DiedDisconnect
            }
        NT.ErrorEvent _ ->
          fail "handleIncomingMessages: TODO 4"
        NT.EndPointClosed ->
          return ()
        NT.ReceivedMulticast _ _ ->
          fail "Unexpected multicast"
    
    state    = localState node
    endpoint = localEndPoint node
    ctrlChan = localCtrlChan node

--------------------------------------------------------------------------------
-- Auxiliary functions                                                        --
--------------------------------------------------------------------------------

getConnectionTo :: ProcessId -> Process (Maybe NT.Connection)
getConnectionTo them = do
  ourState <- processState <$> ask
  mConn <- liftIO $ withMVar ourState $ return . (^. connectionTo them)
  case mConn of
    Just conn -> return . Just $ conn
    Nothing   -> createConnectionTo them

createConnectionTo :: ProcessId -> Process (Maybe NT.Connection)
createConnectionTo them = do 
  proc <- ask
  mConn <- liftIO $ NT.connect (localEndPoint . processNode $ proc) 
                               (nodeAddress . processNodeId $ them)  
                               NT.ReliableOrdered
                               NT.defaultConnectHints
  case mConn of
    Right conn -> do
      mConn' <- liftIO $ modifyMVar (processState proc) $ \st ->
        case st ^. connectionTo them of
          Just conn' -> return (st, Just conn')
          Nothing    -> return (connectionTo them ^= Just conn $ st, Nothing)
      case mConn' of
        Just conn' -> do
          -- Somebody else already created a connection while we weren't looking
          -- (We don't want to keep localConnections locked while creating the
          -- connection because that would limit concurrency too much, and
          -- since Network.Transport supports lgihtweight connections creating
          -- an unnecessary connection now and then is cheap anyway)
          liftIO $ NT.close conn
          return . Just $ conn'
        Nothing -> do
          sendBinary them conn . idToPayload . Just . processLocalId $ them 
          return . Just $ conn
    Left _err -> do
      -- TODO: should probably pass this error to remoteProcessFailed
      node <- processNode <$> ask 
      liftIO $ remoteProcessFailed node them
      return Nothing 

sendBinary :: ProcessId -> NT.Connection -> [BSS.ByteString] -> Process () 
sendBinary them conn payload = do
  result <- liftIO $ NT.send conn payload 
  case result of
    Right () -> 
      return ()
    Left _ -> do
      node <- processNode <$> ask 
      liftIO $ remoteProcessFailed node them

sendMessage :: ProcessId -> NT.Connection -> Message -> Process ()
sendMessage them conn = sendBinary them conn . messageToPayload 

remoteProcessFailed :: LocalNode -> ProcessId -> IO ()
remoteProcessFailed node them = do
  -- [Unified: Table 9 rule node_disconnect]
  let nid = Right (processNodeId them)
  writeChan (localCtrlChan node) NCMsg
    { ctrlMsgSender = nid 
    , ctrlMsgSignal = Died nid DiedDisconnect 
    }
    
getMonitorRefFor :: ProcessId -> Process MonitorRef
getMonitorRefFor pid = do
  node <- processNode <$> ask
  liftIO $ modifyMVar (localState node) $ \st -> do
    let counter = st ^. localMonitorCounter
    return ( localMonitorCounter ^: (+ 1) $ st
           , MonitorRef pid counter 
           )

-- This is most definitely NOT exported
runLocalProcess :: LocalProcess -> Process a -> IO a
runLocalProcess lproc proc = runReaderT (unProcess proc) lproc

-- | Post a control message on the local node controller
postCtrlMsg :: ProcessSignal -> Process ()
postCtrlMsg signal = do
  us <- getSelfPid
  ctrlChan <- localCtrlChan . processNode <$> ask
  liftIO $ writeChan ctrlChan NCMsg { ctrlMsgSender = Left us
                                    , ctrlMsgSignal = signal
                                    }
