-- | Local nodes
module Control.Distributed.Process.Node 
  ( LocalNode
  , newLocalNode
  , closeLocalNode
  , forkProcess
  , runProcess
  , initRemoteTable
  , localNodeId
  ) where

import Prelude hiding (catch)
import System.IO (fixIO, hPutStrLn, stderr)
import qualified Data.ByteString.Lazy as BSL (fromChunks)
import Data.Binary (decode)
import Data.Map (Map)
import qualified Data.Map as Map 
  ( empty
  , lookup
  , insert
  , delete
  , toList
  , partitionWithKey
  , filterWithKey
  )
import qualified Data.List as List (delete, (\\))
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert, delete, member, (\\), fromList)
import Data.Foldable (forM_)
import Data.Maybe (isJust, fromMaybe)
import Data.Typeable (Typeable)
import Control.Category ((>>>))
import Control.Applicative ((<$>))
import Control.Monad (void, when, forever)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State (MonadState, StateT, evalStateT, gets, modify)
import qualified Control.Monad.Trans.Class as Trans (lift)
import Control.Exception (throwIO, SomeException, Exception, throwTo)
import qualified Control.Exception as Exception (catch)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar 
  ( newMVar 
  , withMVar
  , modifyMVar
  , modifyMVar_
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Concurrent.Chan (newChan, writeChan, readChan)
import Control.Concurrent.STM (atomically, writeTChan)
import Control.Distributed.Process.Internal.CQueue (enqueue, newCQueue)
import qualified Network.Transport as NT 
  ( Transport
  , EndPoint
  , newEndPoint
  , receive
  , Event(..)
  , EventErrorCode(..)
  , TransportError(..)
  , address
  , closeEndPoint
  , ConnectionId
  )
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapDefault, mapMaybe)
import System.Random (randomIO)
import Control.Distributed.Process.Internal.Types 
  ( RemoteTable
  , NodeId(..)
  , LocalProcessId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalNodeState(..)
  , LocalProcess(..)
  , LocalProcessState(..)
  , Process(..)
  , DiedReason(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , localPidCounter
  , localPidUnique
  , localProcessWithId
  , MonitorRef(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , DidUnmonitor(..)
  , DidUnlinkProcess(..)
  , DidUnlinkNode(..)
  , DidUnlinkPort(..)
  , SpawnRef
  , DidSpawn(..)
  , Closure(..)
  , Static(..)
  , Message
  , MessageT
  , TypedChannel(..)
  , Identifier(..)
  , nodeOf
  , SendPortId(..)
  , typedChannelWithId
  , WhereIsReply(..)
  , messageToPayload
  , RemoteTable(..)
  )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.MessageT 
  ( sendBinary
  , sendMessage
  , sendPayload
  , getLocalNode
  , runMessageT
  , payloadToMessage
  , createMessage
  )
import Control.Distributed.Process.Internal.Dynamic (fromDynamic)
import Control.Distributed.Process.Internal.Closure.Resolution (resolveClosure) 
import Control.Distributed.Process.Internal.Node (runLocalProcess)
import Control.Distributed.Process.Internal.Primitives (expect, register)
import qualified Control.Distributed.Process.Internal.Closure.Derived as Derived (remoteTable)

--------------------------------------------------------------------------------
-- Initialization                                                             --
--------------------------------------------------------------------------------

initRemoteTable :: RemoteTable
initRemoteTable = Derived.remoteTable $ RemoteTable Map.empty Map.empty 

-- | Initialize a new local node. 
-- 
-- Note that proper Cloud Haskell initialization and configuration is still 
-- to do.
newLocalNode :: NT.Transport -> RemoteTable -> IO LocalNode
newLocalNode transport rtable = do
    mEndPoint <- NT.newEndPoint transport
    case mEndPoint of
      Left ex -> throwIO ex
      Right endPoint -> do
        localNode <- createBareLocalNode endPoint rtable 
        startServiceProcesses localNode
        return localNode
    
-- | Create a new local node (without any service processes running)
createBareLocalNode :: NT.EndPoint -> RemoteTable -> IO LocalNode
createBareLocalNode endPoint rtable = do
  unq <- randomIO
  state <- newMVar LocalNodeState 
    { _localProcesses      = Map.empty
    , _localPidCounter     = 0 
    , _localPidUnique      = unq 
    }
  ctrlChan <- newChan
  let node = LocalNode { localNodeId   = NodeId $ NT.address endPoint
                       , localEndPoint = endPoint
                       , localState    = state
                       , localCtrlChan = ctrlChan
                       , remoteTable   = rtable
                       }
  void . forkIO $ runNodeController node 
  void . forkIO $ handleIncomingMessages node
  return node

-- | Start and register the service processes on a node 
-- (for now, this is only the logger)
startServiceProcesses :: LocalNode -> IO ()
startServiceProcesses node = do
  logger <- forkProcess node . forever $ do
    (time, pid, string) <- expect :: Process (String, ProcessId, String)
    liftIO . hPutStrLn stderr $ time ++ " " ++ show pid ++ ": " ++ string 
  runProcess node $ register "logger" logger

-- | Force-close a local node
--
-- TODO: for now we just close the associated endpoint
closeLocalNode :: LocalNode -> IO ()
closeLocalNode node =
  NT.closeEndPoint (localEndPoint node)

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
  pst <- newMVar LocalProcessState { _monitorCounter = 0
                                   , _spawnCounter   = 0
                                   , _channelCounter = 0
                                   , _typedChannels  = Map.empty
                                   }
  queue <- newCQueue
  (_, lproc) <- fixIO $ \ ~(tid, _) -> do
    let lproc = LocalProcess { processQueue  = queue
                             , processId     = pid
                             , processState  = pst 
                             , processThread = tid
                             }
    tid' <- forkIO $ do
      reason <- Exception.catch 
        (runLocalProcess node proc lproc >> return DiedNormal)
        (return . DiedException . (show :: SomeException -> String))
      -- [Unified: Table 4, rules termination and exiting]
      modifyMVar_ (localState node) $ 
        return . (localProcessWithId lpid ^= Nothing)
      writeChan (localCtrlChan node) NCMsg 
        { ctrlMsgSender = ProcessIdentifier pid 
        , ctrlMsgSignal = Died (ProcessIdentifier pid) reason 
        }
    return (tid', lproc)

  if lpidCounter lpid == maxBound
    then do
      newUnique <- randomIO
      return ( (localProcessWithId lpid ^= Just lproc)
             . (localPidCounter ^= 0)
             . (localPidUnique ^= newUnique)
             $ st
             , pid
             )
    else
      return ( (localProcessWithId lpid ^= Just lproc)
             . (localPidCounter ^: (+ 1))
             $ st
             , pid 
             )

handleIncomingMessages :: LocalNode -> IO ()
handleIncomingMessages node = go [] Map.empty Map.empty Set.empty
  where
    go :: [NT.ConnectionId] -- ^ Connections whose purpose we don't yet know 
       -> Map NT.ConnectionId LocalProcess -- ^ Connections to local processes
       -> Map NT.ConnectionId TypedChannel -- ^ Connections to typed channels
       -> Set NT.ConnectionId              -- ^ Connections to our controller
       -> IO () 
    go uninitConns procs chans ctrls = do
      event <- NT.receive endpoint
      case event of
        NT.ConnectionOpened cid _rel _theirAddr ->
          -- TODO: Check if _rel is ReliableOrdered, and if not, treat as
          -- (**) below.
          go (cid : uninitConns) procs chans ctrls 
        NT.Received cid payload -> 
          case ( Map.lookup cid procs 
               , Map.lookup cid chans
               , cid `Set.member` ctrls
               , cid `elem` uninitConns
               ) of
            (Just proc, _, _, _) -> do
              let msg = payloadToMessage payload
              enqueue (processQueue proc) msg
              go uninitConns procs chans ctrls 
            (_, Just (TypedChannel chan), _, _) -> do
              atomically $ writeTChan chan . decode . BSL.fromChunks $ payload
              go uninitConns procs chans ctrls 
            (_, _, True, _) -> do
              let ctrlMsg = decode . BSL.fromChunks $ payload
              writeChan ctrlChan ctrlMsg
              go uninitConns procs chans ctrls 
            (_, _, _, True) -> 
              case decode (BSL.fromChunks payload) of
                ProcessIdentifier pid -> do
                  let lpid = processLocalId pid
                  mProc <- withMVar state $ return . (^. localProcessWithId lpid) 
                  case mProc of
                    Just proc -> 
                      go (List.delete cid uninitConns) 
                         (Map.insert cid proc procs)
                         chans
                         ctrls
                    Nothing ->
                      -- Request for an unknown process. 
                      --
                      -- TODO: We should treat this as a fatal error on the
                      -- part of the remote node. That is, we should report the
                      -- remote node as having died, and we should close
                      -- incoming connections (this requires a Transport layer
                      -- extension). (**)
                      go (List.delete cid uninitConns) procs chans ctrls
                SendPortIdentifier chId -> do
                  let lcid = sendPortLocalId chId
                      lpid = processLocalId (sendPortProcessId chId)
                  mProc <- withMVar state $ return . (^. localProcessWithId lpid)
                  case mProc of
                    Just proc -> do
                      mChannel <- withMVar (processState proc) $ return . (^. typedChannelWithId lcid)
                      case mChannel of
                        Just channel ->
                          go (List.delete cid uninitConns)
                             procs
                             (Map.insert cid channel chans)
                             ctrls
                        Nothing ->
                          -- Unknown typed channel
                          -- TODO (**) above
                          go (List.delete cid uninitConns) procs chans ctrls
                    Nothing ->
                      -- Unknown process
                      -- TODO (**) above
                      go (List.delete cid uninitConns) procs chans ctrls
                NodeIdentifier _ ->
                  go (List.delete cid uninitConns)
                     procs
                     chans
                     (Set.insert cid ctrls)
            _ ->
              -- Unexpected message
              -- TODO (**) above 
              go uninitConns procs chans ctrls
        NT.ConnectionClosed cid -> 
          go (List.delete cid uninitConns) 
             (Map.delete cid procs)
             (Map.delete cid chans)
             (Set.delete cid ctrls)
        NT.ErrorEvent (NT.TransportError (NT.EventConnectionLost (Just theirAddr) cids) _) -> do 
          -- [Unified table 9, rule node_disconnect]
          let nid = NodeIdentifier $ NodeId theirAddr
          writeChan ctrlChan NCMsg 
            { ctrlMsgSender = nid
            , ctrlMsgSignal = Died nid DiedDisconnect
            }
          go (uninitConns List.\\ cids)
             (Map.filterWithKey (\k _ -> k `notElem` cids) procs)
             (Map.filterWithKey (\k _ -> k `notElem` cids) chans)
             (ctrls Set.\\ Set.fromList cids)
        NT.ErrorEvent (NT.TransportError (NT.EventConnectionLost Nothing _) _) ->
          -- TODO: We should treat an asymetrical connection loss (incoming
          -- connection broken, but outgoing connection still potentially ok)
          -- as a fatal error on the part of the remote node (like (**), above)
          fail "handleIncomingMessages: TODO"
        NT.ErrorEvent (NT.TransportError NT.EventEndPointFailed str) ->
          fail $ "Cloud Haskell fatal error: end point failed: " ++ str 
        NT.ErrorEvent (NT.TransportError NT.EventTransportFailed str) ->
          fail $ "Cloud Haskell fatal error: transport failed: " ++ str 
        NT.EndPointClosed ->
          return ()
        NT.ReceivedMulticast _ _ ->
          -- If we received a multicast message, something went horribly wrong
          -- and we just give up
          fail "Cloud Haskell fatal error: received unexpected multicast"
    
    state    = localState node
    endpoint = localEndPoint node
    ctrlChan = localCtrlChan node

--------------------------------------------------------------------------------
-- Top-level access to the node controller                                    --
--------------------------------------------------------------------------------

runNodeController :: LocalNode -> IO ()
runNodeController node =
  runMessageT node (evalStateT (unNC nodeController) initNCState)

--------------------------------------------------------------------------------
-- Internal data types                                                        --
--------------------------------------------------------------------------------

data NCState = NCState 
  {  -- Mapping from remote processes to linked local processes 
    _links    :: Map Identifier (Set ProcessId) 
     -- Mapping from remote processes to monitoring local processes
  , _monitors :: Map Identifier (Set (ProcessId, MonitorRef))
     -- Process registry
  , _registry :: Map String ProcessId
  }

newtype NC a = NC { unNC :: StateT NCState (MessageT IO) a }
  deriving (Functor, Monad, MonadIO, MonadState NCState)

ncMsg :: MessageT IO a -> NC a
ncMsg = NC . Trans.lift

initNCState :: NCState
initNCState = NCState { _links    = Map.empty
                      , _monitors = Map.empty
                      , _registry = Map.empty
                      }

--------------------------------------------------------------------------------
-- Core functionality                                                         --
--------------------------------------------------------------------------------

-- [Unified: Table 7]
nodeController :: NC ()
nodeController = do
  node <- ncMsg getLocalNode 
  forever $ do
    msg  <- liftIO $ readChan (localCtrlChan node)

    -- [Unified: Table 7, rule nc_forward] 
    case destNid (ctrlMsgSignal msg) of
      Just nid' | nid' /= localNodeId node -> 
        ncMsg $ sendBinary (NodeIdentifier nid') msg
      _ -> 
        return ()

    case msg of
      NCMsg (ProcessIdentifier from) (Link them) ->
        ncEffectMonitor from them Nothing
      NCMsg (ProcessIdentifier from) (Monitor ref) ->
        ncEffectMonitor from (monitorRefIdent ref) (Just ref)
      NCMsg (ProcessIdentifier from) (Unlink them) ->
        ncEffectUnlink from them 
      NCMsg (ProcessIdentifier from) (Unmonitor ref) ->
        ncEffectUnmonitor from ref
      NCMsg _from (Died ident reason) ->
        ncEffectDied ident reason
      NCMsg (ProcessIdentifier from) (Spawn proc ref) ->
        ncEffectSpawn from proc ref
      NCMsg _from (Register label pid) ->
        ncEffectRegister label pid
      NCMsg (ProcessIdentifier from) (WhereIs label) ->
        ncEffectWhereIs from label
      NCMsg from (NamedSend label msg') ->
        ncEffectNamedSend from label msg'
      unexpected ->
        error $ "nodeController: unexpected message " ++ show unexpected

-- [Unified: Table 10]
ncEffectMonitor :: ProcessId        -- ^ Who's watching? 
                -> Identifier       -- ^ Who's being watched?
                -> Maybe MonitorRef -- ^ 'Nothing' to link
                -> NC ()
ncEffectMonitor from them mRef = do
  node <- ncMsg getLocalNode 
  shouldLink <- 
    if not (isLocal node them) 
      then return True
      else isValidLocalIdentifier them
  case (shouldLink, isLocal node (ProcessIdentifier from)) of
    (True, _) ->  -- [Unified: first rule]
      case mRef of
        Just ref -> modify $ monitorsFor them ^: Set.insert (from, ref)
        Nothing  -> modify $ linksFor them ^: Set.insert from 
    (False, True) -> -- [Unified: second rule]
      notifyDied from them DiedUnknownId mRef 
    (False, False) -> -- [Unified: third rule]
      ncMsg $ sendBinary (NodeIdentifier $ processNodeId from) NCMsg 
        { ctrlMsgSender = NodeIdentifier (localNodeId node)
        , ctrlMsgSignal = Died them DiedUnknownId
        }

-- [Unified: Table 11]
ncEffectUnlink :: ProcessId -> Identifier -> NC ()
ncEffectUnlink from them = do
  node <- ncMsg getLocalNode 
  when (isLocal node (ProcessIdentifier from)) $ 
    case them of
      ProcessIdentifier pid -> 
        postAsMessage from $ DidUnlinkProcess pid 
      NodeIdentifier nid -> 
        postAsMessage from $ DidUnlinkNode nid
      SendPortIdentifier cid -> 
        postAsMessage from $ DidUnlinkPort cid 
  modify $ linksFor them ^: Set.delete from

-- [Unified: Table 11]
ncEffectUnmonitor :: ProcessId -> MonitorRef -> NC ()
ncEffectUnmonitor from ref = do
  node <- ncMsg getLocalNode 
  when (isLocal node (ProcessIdentifier from)) $ 
    postAsMessage from $ DidUnmonitor ref
  modify $ monitorsFor (monitorRefIdent ref) ^: Set.delete (from, ref)

-- [Unified: Table 12]
ncEffectDied :: Identifier -> DiedReason -> NC ()
ncEffectDied ident reason = do
  node <- ncMsg getLocalNode
  (affectedLinks, unaffectedLinks) <- gets (splitNotif ident . (^. links))
  (affectedMons,  unaffectedMons)  <- gets (splitNotif ident . (^. monitors))

  let localOnly = case ident of NodeIdentifier _ -> True ; _ -> False

  forM_ (Map.toList affectedLinks) $ \(them, uss) -> 
    forM_ uss $ \us ->
      when (localOnly <= isLocal node (ProcessIdentifier us)) $ 
        notifyDied us them reason Nothing

  forM_ (Map.toList affectedMons) $ \(them, refs) ->
    forM_ refs $ \(us, ref) ->
      when (localOnly <= isLocal node (ProcessIdentifier us)) $
        notifyDied us them reason (Just ref)

  modify $ (links ^= unaffectedLinks) . (monitors ^= unaffectedMons)

-- [Unified: Table 13]
ncEffectSpawn :: ProcessId -> Closure (Process ()) -> SpawnRef -> NC ()
ncEffectSpawn pid cProc ref = do
  mProc <- unClosure cProc
  -- If the closure does not exist, we spawn a process that throws an exception
  -- This allows the remote node to find out what's happening
  let proc = fromMaybe (fail $ "Error: unknown closure " ++ show cProc) mProc
  node <- ncMsg getLocalNode
  pid' <- liftIO $ forkProcess node proc
  ncMsg $ sendMessage (ProcessIdentifier pid) (DidSpawn ref pid') 

-- Unified semantics does not explicitly describe how to implement 'register',
-- but mentions it's "very similar to nsend" (Table 14)
ncEffectRegister :: String -> Maybe ProcessId -> NC ()
ncEffectRegister label mPid = 
  modify $ registryFor label ^= mPid
  -- An acknowledgement is not necessary. If we want a synchronous register,
  -- it suffices to send a whereis requiry immediately after the register
  -- (that may not suffice if we do decide for unreliable messaging instead)

-- Unified semantics does not explicitly describe 'whereis'
ncEffectWhereIs :: ProcessId -> String -> NC ()
ncEffectWhereIs from label = do
  mPid <- gets (^. registryFor label)
  ncMsg $ sendMessage (ProcessIdentifier from) (WhereIsReply label mPid)

-- [Unified: Table 14]
ncEffectNamedSend :: Identifier -> String -> Message -> NC ()
ncEffectNamedSend _from label msg = do
  mPid <- gets (^. registryFor label)
  -- If mPid is Nothing, we just ignore the named send (as per Table 14)
  -- TODO: messages don't carry a "from", but if they do, we should set it
  -- to be the 'from' of the original named send, not this node controller
  forM_ mPid $ \pid -> 
    ncMsg $ sendPayload (ProcessIdentifier pid) (messageToPayload msg) 

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

notifyDied :: ProcessId         -- ^ Who to notify?
           -> Identifier        -- ^ Who died?
           -> DiedReason        -- ^ How did they die?
           -> Maybe MonitorRef  -- ^ 'Nothing' for linking
           -> NC ()
notifyDied dest src reason mRef = do
  node <- ncMsg getLocalNode 
  case (isLocal node (ProcessIdentifier dest), mRef, src) of
    (True, Just ref, ProcessIdentifier pid) ->
      postAsMessage dest $ ProcessMonitorNotification ref pid reason 
    (True, Just ref, NodeIdentifier nid) ->
      postAsMessage dest $ NodeMonitorNotification ref nid reason
    (True, Just ref, SendPortIdentifier cid) ->
      postAsMessage dest $ PortMonitorNotification ref cid reason
    (True, Nothing, ProcessIdentifier pid) ->
      throwException dest $ ProcessLinkException pid reason 
    (True, Nothing, NodeIdentifier pid) ->
      throwException dest $ NodeLinkException pid reason 
    (True, Nothing, SendPortIdentifier pid) ->
      throwException dest $ PortLinkException pid reason 
    (False, _, _) ->
      -- TODO: why the change in sender? How does that affect 'reconnect' semantics?
      -- (see [Unified: Table 10]
      ncMsg $ sendBinary (NodeIdentifier $ processNodeId dest) NCMsg
        { ctrlMsgSender = NodeIdentifier (localNodeId node) 
        , ctrlMsgSignal = Died src reason
        }
      
-- | [Unified: Table 8]
destNid :: ProcessSignal -> Maybe NodeId
destNid (Link ident)    = Just $ nodeOf ident
destNid (Unlink ident)  = Just $ nodeOf ident
destNid (Monitor ref)   = Just $ nodeOf (monitorRefIdent ref)
destNid (Unmonitor ref) = Just $ nodeOf (monitorRefIdent ref)
destNid (Spawn _ _)     = Nothing 
destNid (Register _ _)  = Nothing
destNid (WhereIs _)     = Nothing
destNid (NamedSend _ _) = Nothing
-- We don't need to forward 'Died' signals; if monitoring/linking is setup,
-- then when a local process dies the monitoring/linking machinery will take
-- care of notifying remote nodes
destNid (Died _ _) = Nothing 

-- | Check if a process is local to our own node
isLocal :: LocalNode -> Identifier -> Bool 
isLocal nid ident = nodeOf ident == localNodeId nid

-- | Lookup a local closure 
unClosure :: Typeable a => Closure a -> NC (Maybe a)
unClosure (Closure (Static label) env) = do
  rtable <- remoteTable <$> ncMsg getLocalNode
  return (resolveClosure rtable label env >>= fromDynamic)

-- | Check if an identifier refers to a valid local object
isValidLocalIdentifier :: Identifier -> NC Bool
isValidLocalIdentifier ident = do
  node <- ncMsg getLocalNode
  liftIO . withMVar (localState node) $ \nSt -> 
    case ident of
      NodeIdentifier nid ->
        return $ nid == localNodeId node
      ProcessIdentifier pid -> do
        let mProc = nSt ^. localProcessWithId (processLocalId pid)
        return $ isJust mProc 
      SendPortIdentifier cid -> do
        let pid   = sendPortProcessId cid
            mProc = nSt ^. localProcessWithId (processLocalId pid)
        case mProc of
          Nothing -> return False
          Just proc -> withMVar (processState proc) $ \pSt -> do
            let mCh = pSt ^. typedChannelWithId (sendPortLocalId cid)
            return $ isJust mCh

--------------------------------------------------------------------------------
-- Messages to local processes                                                --
--------------------------------------------------------------------------------

postAsMessage :: Serializable a => ProcessId -> a -> NC ()
postAsMessage pid = postMessage pid . createMessage  

postMessage :: ProcessId -> Message -> NC ()
postMessage pid msg = withLocalProc pid $ \p -> enqueue (processQueue p) msg

throwException :: Exception e => ProcessId -> e -> NC ()
throwException pid e = withLocalProc pid $ \p -> 
  throwTo (processThread p) e

withLocalProc :: ProcessId -> (LocalProcess -> IO ()) -> NC () 
withLocalProc pid p = do
  node <- ncMsg getLocalNode 
  liftIO $ do 
    -- By [Unified: table 6, rule missing_process] messages to dead processes
    -- can silently be dropped
    let lpid = processLocalId pid
    mProc <- withMVar (localState node) $ return . (^. localProcessWithId lpid)
    forM_ mProc p 

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

links :: Accessor NCState (Map Identifier (Set ProcessId))
links = accessor _links (\ls st -> st { _links = ls })

monitors :: Accessor NCState (Map Identifier (Set (ProcessId, MonitorRef)))
monitors = accessor _monitors (\ms st -> st { _monitors = ms })

registry :: Accessor NCState (Map String ProcessId)
registry = accessor _registry (\ry st -> st { _registry = ry })

linksFor :: Identifier -> Accessor NCState (Set ProcessId)
linksFor ident = links >>> DAC.mapDefault Set.empty ident

monitorsFor :: Identifier -> Accessor NCState (Set (ProcessId, MonitorRef))
monitorsFor ident = monitors >>> DAC.mapDefault Set.empty ident

registryFor :: String -> Accessor NCState (Maybe ProcessId)
registryFor ident = registry >>> DAC.mapMaybe ident

-- | @splitNotif ident@ splits a notifications map into those
-- notifications that should trigger when 'ident' fails and those links that
-- should not.
--
-- There is a hierarchy between identifiers: failure of a node implies failure
-- of all processes on that node, and failure of a process implies failure of
-- all typed channels to that process. In other words, if 'ident' refers to a
-- node, then the /should trigger/ set will include 
--
-- * the notifications for the node specifically
-- * the notifications for processes on that node, and 
-- * the notifications for typed channels to processes on that node. 
--
-- Similarly, if 'ident' refers to a process, the /should trigger/ set will
-- include 
--
-- * the notifications for that process specifically and 
-- * the notifications for typed channels to that process.
splitNotif :: Identifier
           -> Map Identifier a
           -> (Map Identifier a, Map Identifier a)
splitNotif ident = Map.partitionWithKey (const . impliesDeathOf ident)

-- | Does the death of one entity (node, project, channel) imply the death
-- of another?
impliesDeathOf :: Identifier -- ^ Who died 
               -> Identifier -- ^ Who's being watched 
               -> Bool       -- ^ Does this death implies the death of the watchee? 
NodeIdentifier nid `impliesDeathOf` NodeIdentifier nid' = 
  nid' == nid
NodeIdentifier nid `impliesDeathOf` ProcessIdentifier pid =
  processNodeId pid == nid
NodeIdentifier nid `impliesDeathOf` SendPortIdentifier cid =
  processNodeId (sendPortProcessId cid) == nid
ProcessIdentifier pid `impliesDeathOf` ProcessIdentifier pid' =
  pid' == pid
ProcessIdentifier pid `impliesDeathOf` SendPortIdentifier cid =
  sendPortProcessId cid == pid
SendPortIdentifier cid `impliesDeathOf` SendPortIdentifier cid' =
  cid' == cid
_ `impliesDeathOf` _ =
  False
