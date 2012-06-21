-- | Local nodes
module Control.Distributed.Process.Node 
  ( newLocalNode
  , closeLocalNode
  , forkProcess
  , runProcess
  , initRemoteTable
  , localNodeId
  ) where

import Prelude hiding (catch)
import System.IO (fixIO)
import qualified Data.ByteString.Lazy as BSL (fromChunks)
import Data.Binary (decode)
import Data.Map (Map)
import qualified Data.Map as Map (empty, lookup, insert, delete, toList)
import qualified Data.List as List (delete)
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert, delete, member)
import Data.Foldable (forM_)
import Data.Maybe (isJust)
import Data.Typeable (Typeable)
import Data.Dynamic (fromDynamic)
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
import qualified Data.Accessor.Container as DAC (mapDefault)
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
  , runLocalProcess
  , DiedReason(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , payloadToMessage
  , localPidCounter
  , localPidUnique
  , localProcessWithId
  , initRemoteTable
  , MonitorRef(..)
  , MonitorNotification(..)
  , LinkException(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
  , SpawnRef
  , DidSpawn(..)
  , Closure(..)
  , Static(..)
  , createMessage
  , MessageT
  , runMessageT
  , TypedChannel(..)
  , Identifier(..)
  , ChannelId(..)
  , typedChannelWithId
  )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.MessageT 
  ( sendBinary
  , sendMessage
  , getLocalNode
  )

--------------------------------------------------------------------------------
-- Initialization                                                             --
--------------------------------------------------------------------------------

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

  -- TODO: if the counter overflows we should pick a new unique                           
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
              writeChan ctrlChan (decode . BSL.fromChunks $ payload)
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
                      -- TODO: We should close the incoming connection here, but
                      -- we cannot! Network.Transport does not provide this 
                      -- functionality. Not sure what the right approach is.
                      -- For now, we just drop the incoming messages 
                      go (List.delete cid uninitConns) procs chans ctrls
                ChannelIdentifier chId -> do
                  let lcid = channelLocalId chId
                      lpid = processLocalId (channelProcessId chId)
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
                          go (List.delete cid uninitConns) procs chans ctrls
                    Nothing ->
                      go (List.delete cid uninitConns) procs chans ctrls
                NodeIdentifier _ ->
                  go (List.delete cid uninitConns)
                     procs
                     chans
                     (Set.insert cid ctrls)
            _ ->
              -- Unexpected message. We just drop it.
              go uninitConns procs chans ctrls
        NT.ConnectionClosed cid -> 
          go (List.delete cid uninitConns) 
             (Map.delete cid procs)
             (Map.delete cid chans)
             (Set.delete cid ctrls)
        NT.ErrorEvent (NT.TransportError (NT.EventConnectionLost (Just theirAddr) _) _) -> do 
          -- [Unified table 9, rule node_disconnect]
          let nid = NodeIdentifier $ NodeId theirAddr
          writeChan ctrlChan NCMsg 
            { ctrlMsgSender = nid
            , ctrlMsgSignal = Died nid DiedDisconnect
            }
        NT.ErrorEvent _ ->
          fail "handleIncomingMessages: TODO 3"
        NT.EndPointClosed ->
          return ()
        NT.ReceivedMulticast _ _ ->
          fail "handleIncomingMessages: TODO 4"
    
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
    _links    :: Map NodeId (Map LocalProcessId (Set ProcessId))
     -- Mapping from remote processes to monitoring local processes
  , _monitors :: Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
  }

newtype NC a = NC { unNC :: StateT NCState (MessageT IO) a }
  deriving (Functor, Monad, MonadIO, MonadState NCState)

lift :: MessageT IO a -> NC a
lift = NC . Trans.lift

initNCState :: NCState
initNCState = NCState { _links    = Map.empty
                      , _monitors = Map.empty
                      }

--------------------------------------------------------------------------------
-- Core functionality                                                         --
--------------------------------------------------------------------------------

-- [Unified: Table 7]
nodeController :: NC ()
nodeController = do
  node <- lift getLocalNode 
  forever $ do
    msg  <- liftIO $ readChan (localCtrlChan node)

    -- [Unified: Table 7, rule nc_forward] 
    case destNid (ctrlMsgSignal msg) of
      Just nid' | nid' /= localNodeId node -> 
        lift $ sendBinary (NodeIdentifier nid') msg
      _ -> 
        return ()

    case msg of
      NCMsg (ProcessIdentifier from) (Link them) ->
        ncEffectMonitor from them Nothing
      NCMsg (ProcessIdentifier from) (Monitor them ref) ->
        ncEffectMonitor from them (Just ref)
      NCMsg (ProcessIdentifier from) (Unlink them) ->
        ncEffectUnlink from them 
      NCMsg (ProcessIdentifier from) (Unmonitor ref) ->
        ncEffectUnmonitor from ref
      NCMsg _from (Died (NodeIdentifier nid) reason) ->
        ncEffectNodeDied nid reason
      NCMsg _from (Died (ProcessIdentifier pid) reason) ->
        ncEffectProcessDied pid reason
      NCMsg (ProcessIdentifier from) (Spawn proc ref) ->
        ncEffectSpawn from proc ref
      unexpected ->
        error $ "Unexpected message " ++ show unexpected

-- [Unified: Table 10]
ncEffectMonitor :: ProcessId        -- ^ Who's watching? 
                -> ProcessId        -- ^ Who's being watched?
                -> Maybe MonitorRef -- ^ 'Nothing' to link
                -> NC ()
ncEffectMonitor from them mRef = do
  node <- lift getLocalNode 
  shouldLink <- 
    if not (isLocal node them) 
      then return True
      else liftIO . withMVar (localState node) $ 
        return . isJust . (^. localProcessWithId (processLocalId them))
  case (shouldLink, isLocal node from) of
    (True, _) ->  -- [Unified: first rule]
      case mRef of
        Just ref -> modify $ monitorsFor them from ^: Set.insert ref
        Nothing  -> modify $ linksForProcess them ^: Set.insert from 
    (False, True) -> -- [Unified: second rule]
      notifyDied from them DiedNoProc mRef 
    (False, False) -> -- [Unified: third rule]
      lift $ sendBinary (NodeIdentifier $ processNodeId from) NCMsg 
        { ctrlMsgSender = NodeIdentifier (localNodeId node)
        , ctrlMsgSignal = Died (ProcessIdentifier them) DiedNoProc
        }

-- [Unified: Table 11]
ncEffectUnlink :: ProcessId -> ProcessId -> NC ()
ncEffectUnlink from them = do
  node <- lift getLocalNode 
  when (isLocal node from) $ postMessage from $ DidUnlink them 
  modify $ linksForProcess them ^: Set.delete from

-- [Unified: Table 11]
ncEffectUnmonitor :: ProcessId -> MonitorRef -> NC ()
ncEffectUnmonitor from ref = do
  node <- lift getLocalNode 
  when (isLocal node from) $ postMessage from $ DidUnmonitor ref
  modify $ monitorsFor (monitorRefPid ref) from ^: Set.delete ref 

-- [Unified: Table 12, bottom rule]
ncEffectNodeDied :: NodeId -> DiedReason -> NC ()
ncEffectNodeDied nid reason = do
  node <- lift getLocalNode 
  lnks <- gets (^. linksForNode nid)
  mons <- gets (^. monitorsForNode nid)

  -- We only need to notify local processes
  forM_ (Map.toList lnks) $ \(them, uss) -> do
    let pid = ProcessId nid them
    forM_ uss $ \us ->
      when (isLocal node us) $ 
        notifyDied us pid reason Nothing

  forM_ (Map.toList mons) $ \(them, uss) -> do
    let pid = ProcessId nid them 
    forM_ (Map.toList uss) $ \(us, refs) -> 
      when (isLocal node us) $
        forM_ refs $ notifyDied us pid reason . Just

  modify $ (linksForNode nid ^= Map.empty)
         . (monitorsForNode nid ^= Map.empty)

-- [Unified: Table 12, top rule]
ncEffectProcessDied :: ProcessId -> DiedReason -> NC ()
ncEffectProcessDied pid reason = do
  lnks <- gets (^. linksForProcess pid)
  mons <- gets (^. monitorsForProcess pid)

  forM_ lnks $ \us ->
    notifyDied us pid reason Nothing 

  forM_ (Map.toList mons) $ \(us, refs) ->
    forM_ refs $ 
      notifyDied us pid reason . Just

  modify $ (linksForProcess pid ^= Set.empty)
         . (monitorsForProcess pid ^= Map.empty)

-- [Unified: Table 13]
ncEffectSpawn :: ProcessId -> Closure (Process ()) -> SpawnRef -> NC ()
ncEffectSpawn pid cProc ref = do
  mProc <- unClosure cProc
  -- TODO: what should we do when unClosure returns Nothing?
  forM_ mProc $ \proc -> do
    node <- lift getLocalNode
    pid' <- liftIO $ forkProcess node proc
    lift $ sendMessage (ProcessIdentifier pid) (DidSpawn ref pid') 

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

notifyDied :: ProcessId         -- ^ Who to notify?
           -> ProcessId         -- ^ Who died?
           -> DiedReason        -- ^ How did they die?
           -> Maybe MonitorRef  -- ^ 'Nothing' for linking
           -> NC ()
notifyDied dest src reason mRef = do
  node <- lift getLocalNode 
  case (isLocal node dest, mRef) of
    (True, Just ref) ->
      postMessage dest $ MonitorNotification ref src reason
    (True, Nothing) ->
      throwException dest $ LinkException src reason 
    (False, _) ->
      -- TODO: why the change in sender? How does that affect 'reconnect' semantics?
      -- (see [Unified: Table 10]
      lift $ sendBinary (NodeIdentifier $ processNodeId dest) NCMsg
        { ctrlMsgSender = NodeIdentifier (localNodeId node) 
        , ctrlMsgSignal = Died (ProcessIdentifier src) reason
        }
      
-- | [Unified: Table 8]
destNid :: ProcessSignal -> Maybe NodeId
destNid (Link pid) = 
  Just . processNodeId $ pid
destNid (Unlink pid) = 
  Just . processNodeId $ pid
destNid (Monitor pid _) = 
  Just . processNodeId $ pid 
destNid (Unmonitor ref) = 
  Just . processNodeId . monitorRefPid $ ref 
destNid (Died (NodeIdentifier _) _) = 
  Nothing
destNid (Died (ProcessIdentifier _pid) _) = 
  fail "destNid: TODO"
destNid (Died (ChannelIdentifier _cid) _) = 
  fail "destNid: TODO"
destNid (Spawn _ _) = 
  Nothing

-- | Check if a process is local to our own node
isLocal :: LocalNode -> ProcessId -> Bool 
isLocal nid pid = processNodeId pid == localNodeId nid 

-- | Lookup a local closure 
--
-- TODO: Duplication with onClosure in Process
unClosure :: Typeable a => Closure a -> NC (Maybe a)
unClosure (Closure (Static label) env) = do
  rtable <- remoteTable <$> lift getLocalNode
  case Map.lookup label rtable of
    Nothing  -> return Nothing
    Just dyn -> case fromDynamic dyn of
      Nothing  -> return Nothing
      Just dec -> return (Just $ dec env)

--------------------------------------------------------------------------------
-- Messages to local processes                                                --
--------------------------------------------------------------------------------

postMessage :: Serializable a => ProcessId -> a -> NC ()
postMessage pid msg = withLocalProc pid $ \p -> 
  enqueue (processQueue p) (createMessage msg)

throwException :: Exception e => ProcessId -> e -> NC ()
throwException pid e = withLocalProc pid $ \p -> 
  throwTo (processThread p) e

withLocalProc :: ProcessId -> (LocalProcess -> IO ()) -> NC () 
withLocalProc pid p = do
  node <- lift getLocalNode 
  liftIO $ do 
    -- By [Unified: table 6, rule missing_process] messages to dead processes
    -- can silently be dropped
    let lpid = processLocalId pid
    mProc <- withMVar (localState node) $ return . (^. localProcessWithId lpid)
    forM_ mProc p 

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

links :: Accessor NCState (Map NodeId (Map LocalProcessId (Set ProcessId)))
links = accessor _links (\lnks st -> st { _links = lnks })

monitors :: Accessor NCState (Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef))))
monitors = accessor _monitors (\mons st -> st { _monitors = mons })

linksForNode :: NodeId -> Accessor NCState (Map LocalProcessId (Set ProcessId))
linksForNode nid = links >>> DAC.mapDefault Map.empty nid 

monitorsForNode :: NodeId -> Accessor NCState (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
monitorsForNode nid = monitors >>> DAC.mapDefault Map.empty nid 

linksForProcess :: ProcessId -> Accessor NCState (Set ProcessId)
linksForProcess pid = linksForNode (processNodeId pid) >>> DAC.mapDefault Set.empty (processLocalId pid)

monitorsForProcess :: ProcessId -> Accessor NCState (Map ProcessId (Set MonitorRef))
monitorsForProcess pid = monitorsForNode (processNodeId pid) >>> DAC.mapDefault Map.empty (processLocalId pid) 

monitorsFor :: ProcessId -> ProcessId -> Accessor NCState (Set MonitorRef)
monitorsFor them us = monitorsForProcess them >>> DAC.mapDefault Set.empty us 
