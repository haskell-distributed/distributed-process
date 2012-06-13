-- | Cloud Haskell
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
-- Some pointers to related documentation about Erlang, for comparison and
-- inspiration: 
--
-- [1] "Programming Distributed Erlang Applications: Pitfalls and Recipes",
--     Hans Svensson and Lars-Ake Fredlund 
--       http://man.lupaworld.com/content/develop/p37-svensson.pdf
-- [2] The Erlang manual, sections "Message Sending" and "Send" 
--       http://www.erlang.org/doc/reference_manual/processes.html#id82409
--       http://www.erlang.org/doc/reference_manual/expressions.html#send
-- [3] Questions "Is the order of message reception guaranteed?" and
--     "If I send a message, is it guaranteed to reach the receiver?" of
--     the Erlang FAQ
--       http://www.erlang.org/faq/academic.html
-- [4] "Delivery of Messages", post on erlang-questions
--       http://erlang.org/pipermail/erlang-questions/2012-February/064767.html
--
-- TODOs:
--
-- 1. Central MonitorAction mapping, so that we can efficiently execute monitor
--    actions from Network.Transport.receive-ing thread. 
-- 2. Access this mapping from send too, because we cannot rely on
--    EventConnectionLost (although it so happens that with the TCP transport
--    we can). 
-- 3. Modify EvenConnectionLost to have Maybe EndPointAddress
-- 4. Change in API? (you can register multiple monitors, they get MonitorIds.
--    to unregister, to provide the monitor ID -- if we do, unregistering the
--    same ID multiple times is idempotent)
-- 5. You get precisely one notification per monitor
-- 6. When a connection is already broken, monitor notifies immediately
module Control.Distributed.Process 
  ( -- * Basic cloud Haskell API
    ProcessId
  , Process
  , expect
  , send 
  , getSelfPid
    -- * Monitoring and linking
  , monitor
  , MonitorReply(..)
  , DiedReason(..)
    -- * Initialization
  , newLocalNode
  , forkProcess
  , runProcess
    -- * Auxiliary API
  , closeLocalNode
  , pcatch
  , expectTimeout
  ) where

import Prelude hiding (catch)
import qualified Data.ByteString as BSS (ByteString, concat, splitAt)
import qualified Data.ByteString.Lazy as BSL ( ByteString
                                             , toChunks
                                             , fromChunks
                                             , splitAt
                                             )
import Data.Binary (Binary, decode, encode, put, get, putWord8, getWord8)
import Data.Map (Map)
import qualified Data.Map as Map (empty, lookup, insert, delete, keys, toList)
import qualified Data.List as List (delete)
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert, delete, member)
import Data.Int (Int32)
import Data.Typeable (Typeable)
import Data.Foldable (forM_)
import Data.Maybe (isJust)
import Control.Monad (void, when, unless, forever)
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State (MonadState, StateT, evalStateT, gets, modify)
import Control.Applicative ((<$>), (<*>))
import Control.Category ((>>>))
import Control.Exception (Exception, throwIO, catch, SomeException)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar ( MVar
                               , newMVar
                               , withMVar
                               , modifyMVar
                               , modifyMVar_
                               , newEmptyMVar
                               , putMVar
                               , takeMVar
                               )
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Distributed.Process.Internal.CQueue ( CQueue 
                                                   , dequeueMatching
                                                   , enqueue
                                                   , newCQueue
                                                   )
import Control.Distributed.Process.Serializable ( Serializable
                                                , Fingerprint
                                                , encodeFingerprint
                                                , decodeFingerprint
                                                , fingerprint
                                                , sizeOfFingerprint
                                                )
import qualified Network.Transport as NT ( Transport
                                         , EndPoint
                                         , EndPointAddress
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
import qualified Network.Transport.Internal as NTI (encodeInt32, decodeInt32)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe, mapDefault)
import System.Random (randomIO)

-- | A local process ID consists of a seed which distinguishes processes from
-- different instances of the same local node and a counter
data LocalProcessId = LocalProcessId 
  { lpidUnique  :: Int32
  , lpidCounter :: Int32
  }
  deriving (Eq, Ord, Typeable, Show)

-- We identify node IDs and endpoint IDs
newtype NodeId = NodeId { nodeAddress :: NT.EndPointAddress }
  deriving (Show, Eq, Ord, Binary)

-- | A process ID combines a local process with with an endpoint address
-- (in other words, we identify nodes and endpoints)
data ProcessId = ProcessId 
  { processNodeId  :: NodeId
  , processLocalId :: LocalProcessId 
  }
  deriving (Eq, Ord, Typeable, Show)

-- | Messages consist of their typeRep fingerprint and their encoding
data Message = Message 
  { messageFingerprint :: Fingerprint 
  , messageEncoding    :: BSL.ByteString
  }

-- | Local nodes
data LocalNode = LocalNode 
  { localNodeId   :: NodeId
  , localEndPoint :: NT.EndPoint 
  , localState    :: MVar LocalNodeState
  , localCtrlChan :: Chan NodeCtrlMsg
  }

-- | Local node state
data LocalNodeState = LocalNodeState 
  { _localProcesses      :: Map LocalProcessId LocalProcess
  , _localPidCounter     :: Int32
  , _localPidUnique      :: Int32
  , _monitorActions      :: Map ProcessId [IO ()]
  , _localMonitorCounter :: Int32
  }

-- | Processes running on our local node
data LocalProcess = LocalProcess 
  { processQueue :: CQueue Message 
  , processNode  :: LocalNode   
  , processId    :: ProcessId
  , processState :: MVar LocalProcessState
  }

-- | Local process state
data LocalProcessState = LocalProcessState
  { _connections    :: Map ProcessId NT.Connection 
  }

-- The Cloud Haskell 'Process' type
newtype Process a = Process { unProcess :: ReaderT LocalProcess IO a }
  deriving (Functor, Monad, MonadIO, MonadReader LocalProcess)

--------------------------------------------------------------------------------
-- Basic Cloud Haskell API                                                    --
--------------------------------------------------------------------------------

-- | Wait for a message of a specific type
expect :: forall a. Serializable a => Process a
expect = do
  queue <- processQueue <$> ask 
  let fp = fingerprint (undefined :: a)
  Just msg <- liftIO $ 
    dequeueMatching queue Nothing ((== fp) . messageFingerprint)
  return (decode . messageEncoding $ msg)

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

monitor :: ProcessId -> Process MonitorRef 
monitor them = do
  us          <- getSelfPid
  monitorRef  <- getMonitorRef
  ourCtrlChan <- localCtrlChan . processNode <$> ask
  liftIO . writeChan ourCtrlChan $ NodeCtrlMsg 
    { ctrlMsgSender = Left us
    , ctrlMsgSignal = Monitor them monitorRef
    }
  return monitorRef

--------------------------------------------------------------------------------
-- Auxiliary API                                                              --
--------------------------------------------------------------------------------

-- Force-close a local node
--
-- TODO: for now we just close the associated endpoint
closeLocalNode :: LocalNode -> IO ()
closeLocalNode node = 
  NT.closeEndPoint (localEndPoint node)

-- Catch exceptions within a process
-- TODO: should this be called simply 'catch'?
pcatch :: Exception e => Process a -> (e -> Process a) -> Process a
pcatch p h = do
  run <- runLocalProcess <$> ask
  liftIO $ catch (run p) (run . h) 

expectTimeout :: forall a. Serializable a => Int -> Process (Maybe a)
expectTimeout timeout = do
  queue <- processQueue <$> ask 
  let fp = fingerprint (undefined :: a)
  msg <- liftIO $ 
    dequeueMatching queue (Just timeout) ((== fp) . messageFingerprint)
  return $ fmap (decode . messageEncoding) msg


--------------------------------------------------------------------------------
-- The node controller                                                        --
--------------------------------------------------------------------------------

data ProcessSignal =
    Monitor ProcessId MonitorRef
  | Died Identifier DiedReason

type MonitorRef = Int32

data MonitorReply = ProcessDied MonitorRef ProcessId DiedReason
  deriving (Typeable)

data DiedReason = 
    DiedNormal
  | DiedException String -- TODO: would prefer SomeException instead of String, but exceptions don't implement Binary
  | DiedDisconnect
  | DiedNodeDown

type Identifier = Either ProcessId NodeId

data NodeCtrlMsg = NodeCtrlMsg 
  { ctrlMsgSender :: Identifier 
  , ctrlMsgSignal :: ProcessSignal
  }

data NodeCtrlState = NodeCtrlState 
  {  -- Mapping from remote processes to linked local processes 
    _nodeCtrlLinks :: Map NodeId (Map LocalProcessId (Set ProcessId))
     -- Mapping from remote processes to monitoring local processes
  , _nodeCtrlMons  :: Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
     -- The node controller maintains its own set of connections
     -- TODO: still not convinced that this is correct
  , _nodeCtrlConns :: Map Identifier NT.Connection 
  }

destNid :: ProcessSignal -> Maybe NodeId
destNid (Monitor pid _)      = Just $ processNodeId pid 
destNid (Died (Right _) _)   = Nothing
destNid (Died (Left _pid) _) = fail "destNid: TODO"

initNodeCtrlState :: NodeCtrlState
initNodeCtrlState = NodeCtrlState
  { _nodeCtrlLinks = Map.empty
  , _nodeCtrlMons  = Map.empty
  , _nodeCtrlConns = Map.empty 
  }

newtype NodeCtrl a = NodeCtrl { unNodeCtrl :: ReaderT LocalNode (StateT NodeCtrlState IO) a }
  deriving (Functor, Monad, MonadIO, MonadState NodeCtrlState, MonadReader LocalNode)

nodeController :: NodeCtrl ()
nodeController = forever $ do
  node <- ask
  msg  <- liftIO $ readChan (localCtrlChan node)

  -- Forward the message if appropriate
  case destNid (ctrlMsgSignal msg) of
    Just nid' | nid' /= localNodeId node -> 
      ctrlSendTo (Right nid') . BSL.toChunks . encode $ msg
    _ ->
      return ()

  processCtrlMsg msg

ctrlSendTo :: Identifier -> [BSS.ByteString] -> NodeCtrl () 
ctrlSendTo them payload = do
  mConn <- ctrlConnTo them
  didSend <- case mConn of
    Just conn -> do
      didSend <- liftIO $ NT.send conn payload
      case didSend of
        Left _   -> return False
        Right () -> return True
    Nothing ->
      return False
  unless didSend $ do
    -- [Unified: Table 9, rule node_disconnect]
    node <- ask
    liftIO . writeChan (localCtrlChan node) $ NodeCtrlMsg 
      { ctrlMsgSender = them 
      , ctrlMsgSignal = Died them DiedDisconnect
      }

ctrlConnTo :: Identifier -> NodeCtrl (Maybe NT.Connection)
ctrlConnTo them = do
  mConn <- gets (^. nodeCtrlConnFor them)
  case mConn of
    Just conn -> return (Just conn)
    Nothing   -> createCtrlConnTo them

createCtrlConnTo :: Identifier -> NodeCtrl (Maybe NT.Connection)
createCtrlConnTo them = do
    node  <- ask
    mConn <- liftIO $ NT.connect (localEndPoint node) 
                                 addr 
                                 NT.ReliableOrdered 
                                 NT.defaultConnectHints 
    case mConn of
      Right conn -> do
        didSend <- liftIO $ NT.send conn firstMsg
        case didSend of
          Left _ -> 
            return Nothing 
          Right () -> do
            modify $ nodeCtrlConnFor them ^= Just conn
            return $ Just conn
      Left _ ->
        return Nothing
  where
    (addr, firstMsg) = case them of
       Left pid  -> ( nodeAddress (processNodeId pid)
                    , idToPayload (Just $ processLocalId pid)
                    )
       Right nid -> ( nodeAddress nid
                    , idToPayload Nothing 
                    )


-- [Unified: ncEffect]
processCtrlMsg :: NodeCtrlMsg -> NodeCtrl ()

-- [Unified: Table 10]
processCtrlMsg (NodeCtrlMsg from (Monitor them ref)) = do
  node <- ask 
  shouldLink <- 
    if processNodeId them /= localNodeId node 
      then return True
      else liftIO . withMVar (localState node) $ 
        return . isJust . (^. localProcessWithId (processLocalId them))
  if shouldLink 
    then
      modify $ nodeCtrlMonsFor them (fromLeft from) ^: Set.insert ref
    else 
      fail "processCtrlMsg: TODO"

-- [Unified: Table 12, bottom rule] 
processCtrlMsg (NodeCtrlMsg _from (Died (Right nid) reason)) = do
  node  <- ask
  links <- gets (^. nodeCtrlLinksForNode nid)
  mons  <- gets (^. nodeCtrlMonsForNode nid)

  forM_ (Map.toList links) $ \(_them, _uss) -> do 
    fail "processCtrlMsg: linking not implemented"

  forM_ (Map.toList mons) $ \(them, uss) -> do
    forM_ (Map.toList uss) $ \(us, refs) -> do
      -- We only need to notify local processes
      when (processNodeId us == localNodeId node) . liftIO $ do
        let lpid = processLocalId us
            rpid = ProcessId nid them 
        forM_ refs $ \ref -> do
          mProc <- withMVar (localState node) $ 
            return . (^. localProcessWithId lpid)
          forM_ mProc $ \proc -> 
            enqueue (processQueue proc) . createMessage $
              ProcessDied ref rpid reason

  modify $ (nodeCtrlLinksForNode nid ^= Map.empty)
         . (nodeCtrlMonsForNode nid ^= Map.empty)

-- [Unified: Table 12, top rule]
processCtrlMsg (NodeCtrlMsg _from (Died (Left pid) reason)) = do
  node  <- ask
  links <- gets (^. nodeCtrlLinksForProcess pid)
  mons  <- gets (^. nodeCtrlMonsForProcess pid)

  forM_ links $ \_us ->
    fail "processCtrlMsg: linking not implemented"

  forM_ (Map.toList mons) $ \(us, refs) ->
    forM_ refs $ \ref -> do
      let msg = createMessage $ ProcessDied ref pid reason
      if processNodeId us == localNodeId node 
        then liftIO $ do
          let lpid = processLocalId us
          mProc <- withMVar (localState node) $
            return . (^. localProcessWithId lpid)
          forM_ mProc $ \proc ->
            enqueue (processQueue proc) msg 
        else do
          ctrlSendTo (Right . processNodeId $ us) . BSL.toChunks . encode $ 
            NodeCtrlMsg
              { ctrlMsgSender = Right (localNodeId node) -- TODO: why the change in sender? How does that affect 'reconnect' semantics?
              , ctrlMsgSignal = Died (Left pid) reason
              }
                 
  modify $ (nodeCtrlLinksForProcess pid ^= Set.empty)
         . (nodeCtrlMonsForProcess pid ^= Map.empty)

--------------------------------------------------------------------------------
-- Initialization                                                             --
--------------------------------------------------------------------------------

newLocalNode :: NT.Transport -> IO LocalNode
newLocalNode transport = do
  mEndPoint <- NT.newEndPoint transport
  case mEndPoint of
    Left ex -> throwIO ex
    Right endPoint -> do
      unq <- randomIO
      state <- newMVar LocalNodeState 
        { _localProcesses      = Map.empty
        , _localPidCounter     = 0 
        , _localPidUnique      = unq 
        , _monitorActions      = Map.empty
        , _localMonitorCounter = 0
        }
      ctrlChan <- newChan
      let node = LocalNode { localNodeId   = NodeId $ NT.address endPoint
                           , localEndPoint = endPoint
                           , localState    = state
                           , localCtrlChan = ctrlChan
                           }
      void . forkIO $ evalStateT (runReaderT (unNodeCtrl nodeController) node) 
                                 initNodeCtrlState
      void . forkIO $ handleIncomingMessages node
      return node

runProcess :: LocalNode -> Process () -> IO ()
runProcess node proc = do
  done <- newEmptyMVar
  void $ forkProcess node (proc >> liftIO (putMVar done ()))
  takeMVar done

forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess node proc = do
    queue <- newCQueue
    lproc <- modifyMVar (localState node) $ \st -> do
      let lpid  = LocalProcessId { lpidCounter = st ^. localPidCounter
                                 , lpidUnique  = st ^. localPidUnique
                                 }
      let pid   = ProcessId { processNodeId  = localNodeId node 
                            , processLocalId = lpid
                            }
      pst <- newMVar LocalProcessState { _connections = Map.empty
                                       }
      let lproc = LocalProcess { processQueue = queue
                               , processNode  = node
                               , processId    = pid
                               , processState = pst 
                               }
      -- TODO: if the counter overflows we should pick a new unique                           
      return ( (localProcessWithId lpid ^= Just lproc)
             . (localPidCounter ^: (+ 1))
             $ st
             , lproc 
             )
    void . forkIO $ do
      catch (do
               runLocalProcess lproc proc
               -- [Unified: Table 4]
               let pid = processId lproc
               writeChan (localCtrlChan node) $ NodeCtrlMsg 
                 { ctrlMsgSender = Left pid 
                 , ctrlMsgSignal = Died (Left pid) DiedNormal 
                 }
            )
            (\ex -> do 
               let pid = processId lproc
                   err = show (ex :: SomeException)
               writeChan (localCtrlChan node) $ NodeCtrlMsg 
                 { ctrlMsgSender = Left pid 
                 , ctrlMsgSignal = Died (Left pid) (DiedException err) 
                 }
            )

    return (processId lproc)
   
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
            Nothing -> if cid `Set.member` ctrlConns 
              then writeChan ctrlChan (decode . BSL.fromChunks $ payload)
              else if cid `elem` uninitConns 
                then case payloadToId payload of
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
                else fail "handleIncomingMessages: TODO 2" 
        NT.ConnectionClosed cid -> 
          go (List.delete cid uninitConns) 
             (Map.delete cid procConns)
             (Set.delete cid ctrlConns)
        NT.ErrorEvent (NT.TransportError (NT.EventConnectionLost theirAddr _) _) -> do 
          -- TODO: we could cache this information
          pids <- withMVar state $ \st -> 
            return $ filter ((== theirAddr) . nodeAddress . processNodeId) 
                   . Map.keys 
                   $ st ^. monitorActions
          forM_ pids $ remoteProcessFailed node 
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

messageToPayload :: Message -> [BSS.ByteString]
messageToPayload (Message fp enc) = encodeFingerprint fp : BSL.toChunks enc

payloadToMessage :: [BSS.ByteString] -> Message
payloadToMessage payload = Message fp msg
  where
    (encFp, msg) = BSL.splitAt (fromIntegral sizeOfFingerprint) 
                 $ BSL.fromChunks payload 
    fp = decodeFingerprint . BSS.concat . BSL.toChunks $ encFp

-- | The first message we send across a connection to indicate the intended
-- recipient. Pass Nothing for the remote node controller
idToPayload :: Maybe LocalProcessId -> [BSS.ByteString]
idToPayload Nothing     = [ NTI.encodeInt32 (0 :: Int) ]
idToPayload (Just lpid) = [ NTI.encodeInt32 (1 :: Int)
                          , NTI.encodeInt32 (lpidCounter lpid)
                          , NTI.encodeInt32 (lpidUnique lpid)
                          ]

-- | Inverse of 'idToPayload'
payloadToId :: [BSS.ByteString] -> Maybe LocalProcessId
payloadToId bss = let (bs1, bss') = BSS.splitAt 4 . BSS.concat $ bss
                      (bs2, bs3)  = BSS.splitAt 4 bss' in
                  case NTI.decodeInt32 bs1 :: Int of
                    0 -> Nothing
                    1 -> Just $ LocalProcessId 
                           { lpidCounter = NTI.decodeInt32 bs2
                           , lpidUnique  = NTI.decodeInt32 bs3
                           }
                    _ -> fail "payloadToId"

remoteProcessFailed :: LocalNode -> ProcessId -> IO ()
remoteProcessFailed node them = do
  liftIO $ modifyMVar_ (localState node) $ \st -> do
    sequence_ (st ^. monitorActionsFor them)
    return (monitorActionsFor them ^= [] $ st)

{-do
  proc <- ask
  let ourState = processState proc
  -- We only execute monitor actions once
  action <- liftIO . modifyMVar ourState $ \st ->
    return (monitorActionFor them ^= Nothing $ st, st ^. monitorActionFor them)
  let err = ProcessMonitorException them SrNoPing 
  liftIO $ case action of
    Just MaMonitor ->
      -- TODO: can/should we avoid this encoding/decoding?
      enqueue (processQueue proc) $ createMessage err 
    Just MaLink ->
      throwIO err 
    Just MaLinkError ->
      throwIO err 
    Nothing -> 
      return ()
 -}

createMessage :: Serializable a => a -> Message
createMessage a = Message (fingerprint a) (encode a)

getMonitorRef :: Process MonitorRef
getMonitorRef = do
  node <- processNode <$> ask
  liftIO $ modifyMVar (localState node) $ \st ->
    return ( localMonitorCounter ^: (+ 1) $ st
           , st ^. localMonitorCounter
           )

-- This is most definitely NOT exported
runLocalProcess :: LocalProcess -> Process a -> IO a
runLocalProcess lproc proc = runReaderT (unProcess proc) lproc

--------------------------------------------------------------------------------
-- Binary instances                                                           --
--------------------------------------------------------------------------------

instance Binary LocalProcessId where
  put lpid = put (lpidUnique lpid) >> put (lpidCounter lpid)
  get      = LocalProcessId <$> get <*> get

instance Binary ProcessId where
  put pid = put (processNodeId pid) >> put (processLocalId pid)
  get     = ProcessId <$> get <*> get

instance Binary MonitorReply where
  put (ProcessDied ref pid reason) = put ref >> put pid >> put reason
  get = ProcessDied <$> get <*> get <*> get

instance Binary NodeCtrlMsg where
  put msg = put (ctrlMsgSender msg) >> put (ctrlMsgSignal msg)
  get     = NodeCtrlMsg <$> get <*> get

instance Binary ProcessSignal where
  put (Monitor pid ref) = putWord8 0 >> put pid >> put ref
  put (Died who reason) = putWord8 1 >> put who >> put reason
  get = do
    header <- getWord8
    case header of
      0 -> Monitor <$> get <*> get
      1 -> Died <$> get <*> get
      _ -> fail "ProcessSignal.get: invalid"

instance Binary DiedReason where
  put DiedNormal        = putWord8 0
  put (DiedException e) = putWord8 1 >> put e 
  put DiedDisconnect    = putWord8 2
  put DiedNodeDown      = putWord8 3
  get = do
    header <- getWord8
    case header of
      0 -> return DiedNormal
      1 -> DiedException <$> get
      2 -> return DiedDisconnect
      3 -> return DiedNodeDown
      _ -> fail "DiedReason.get: invalid"

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localProcesses :: Accessor LocalNodeState (Map LocalProcessId LocalProcess)
localProcesses = accessor _localProcesses (\procs st -> st { _localProcesses = procs })

localPidCounter :: Accessor LocalNodeState Int32
localPidCounter = accessor _localPidCounter (\ctr st -> st { _localPidCounter = ctr })

localPidUnique :: Accessor LocalNodeState Int32
localPidUnique = accessor _localPidUnique (\unq st -> st { _localPidUnique = unq })

monitorActions :: Accessor LocalNodeState (Map ProcessId [IO ()])
monitorActions = accessor _monitorActions (\as st -> st { _monitorActions = as })

localMonitorCounter :: Accessor LocalNodeState Int32
localMonitorCounter = accessor _localMonitorCounter (\ctr st -> st { _localMonitorCounter = ctr }) 

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe LocalProcess)
localProcessWithId lpid = localProcesses >>> DAC.mapMaybe lpid

monitorActionsFor :: ProcessId -> Accessor LocalNodeState [IO ()]
monitorActionsFor pid = monitorActions >>> DAC.mapDefault [] pid

connections :: Accessor LocalProcessState (Map ProcessId NT.Connection)
connections = accessor _connections (\conns st -> st { _connections = conns })

connectionTo :: ProcessId -> Accessor LocalProcessState (Maybe NT.Connection)
connectionTo pid = connections >>> DAC.mapMaybe pid

nodeCtrlLinks :: Accessor NodeCtrlState (Map NodeId (Map LocalProcessId (Set ProcessId)))
nodeCtrlLinks = accessor _nodeCtrlLinks (\links st -> st { _nodeCtrlLinks = links })

nodeCtrlMons :: Accessor NodeCtrlState (Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef))))
nodeCtrlMons = accessor _nodeCtrlMons (\mons st -> st { _nodeCtrlMons = mons })

nodeCtrlConns :: Accessor NodeCtrlState (Map Identifier NT.Connection)
nodeCtrlConns = accessor _nodeCtrlConns (\conns st -> st { _nodeCtrlConns = conns })

nodeCtrlConnFor :: Identifier -> Accessor NodeCtrlState (Maybe NT.Connection)
nodeCtrlConnFor them = nodeCtrlConns >>> DAC.mapMaybe them 

nodeCtrlLinksForNode :: NodeId -> Accessor NodeCtrlState (Map LocalProcessId (Set ProcessId))
nodeCtrlLinksForNode nid = nodeCtrlLinks >>> DAC.mapDefault Map.empty nid 

nodeCtrlMonsForNode :: NodeId -> Accessor NodeCtrlState (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
nodeCtrlMonsForNode nid = nodeCtrlMons >>> DAC.mapDefault Map.empty nid 

nodeCtrlLinksForProcess :: ProcessId -> Accessor NodeCtrlState (Set ProcessId)
nodeCtrlLinksForProcess pid = nodeCtrlLinksForNode (processNodeId pid) >>> DAC.mapDefault Set.empty (processLocalId pid)

nodeCtrlMonsForProcess :: ProcessId -> Accessor NodeCtrlState (Map ProcessId (Set MonitorRef))
nodeCtrlMonsForProcess pid = nodeCtrlMonsForNode (processNodeId pid) >>> DAC.mapDefault Map.empty (processLocalId pid) 

nodeCtrlMonsFor :: ProcessId -> ProcessId -> Accessor NodeCtrlState (Set MonitorRef)
nodeCtrlMonsFor them us = nodeCtrlMonsForProcess them >>> DAC.mapDefault Set.empty us 


--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

fromLeft :: Either a b -> a
fromLeft (Left a)  = a
fromLeft (Right _) = error "fromLeft"

