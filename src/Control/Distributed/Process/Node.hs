-- | Local nodes
--
module Control.Distributed.Process.Node
  ( LocalNode
  , newLocalNode
  , closeLocalNode
  , forkProcess
  , runProcess
  , initRemoteTable
  , localNodeId
  ) where

-- TODO: Calls to 'sendBinary' and co (by the NC) may stall the node controller.

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import System.IO (fixIO, hPutStrLn, stderr)
import System.Mem.Weak (Weak, deRefWeak)
import qualified Data.ByteString.Lazy as BSL (fromChunks)
import Data.Binary (decode)
import Data.Map (Map)
import qualified Data.Map as Map
  ( empty
  , toList
  , fromList
  , filter
  , partitionWithKey
  , elems
  , filterWithKey
  , foldlWithKey
  )
import Data.Set (Set)
import qualified Data.Set as Set
  ( empty
  , insert
  , delete
  , member
  , toList
  )
import Data.Foldable (forM_)
import Data.Maybe (isJust, isNothing, catMaybes)
import Data.Typeable (Typeable)
import Control.Category ((>>>))
import Control.Applicative ((<$>))
import Control.Monad (void, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State.Strict (MonadState, StateT, evalStateT, gets)
import qualified Control.Monad.State.Strict as StateT (get, put)
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask)
import Control.Exception (throwIO, SomeException, Exception, throwTo)
import qualified Control.Exception as Exception (catch)
import Control.Concurrent (forkIO)
import Control.Distributed.Process.Internal.StrictMVar
  ( newMVar
  , withMVar
  , modifyMVar
  , modifyMVar_
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Concurrent.Chan (newChan, writeChan, readChan)
import Control.Concurrent.STM
  ( atomically
  )
import Control.Distributed.Process.Internal.CQueue
  ( CQueue
  , enqueue
  , newCQueue
  , mkWeakCQueue
  )
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
  , Connection
  , close
  , EndPointAddress
  , Reliability(ReliableOrdered)
  )
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import System.Random (randomIO)
import Control.Distributed.Static (RemoteTable, Closure)
import qualified Control.Distributed.Static as Static
  ( unclosure
  , initRemoteTable
  )
import Control.Distributed.Process.Internal.Types
  ( NodeId(..)
  , LocalProcessId(..)
  , ProcessId(..)
  , LocalNode(..)
  , Tracer(InactiveTracer)
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
  , localConnections
  , forever'
  , MonitorRef(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , ProcessExitException(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , DidUnmonitor(..)
  , DidUnlinkProcess(..)
  , DidUnlinkNode(..)
  , DidUnlinkPort(..)
  , SpawnRef
  , DidSpawn(..)
  , Message(..)
  , TypedChannel(..)
  , Identifier(..)
  , nodeOf
  , ProcessInfo(..)
  , ProcessInfoNone(..)
  , SendPortId(..)
  , typedChannelWithId
  , RegisterReply(..)
  , WhereIsReply(..)
  , messageToPayload
  , payloadToMessage
  , createUnencodedMessage
  , runLocalProcess
  , firstNonReservedProcessId
  , ImplicitReconnect(WithImplicitReconnect, NoImplicitReconnect)
  )
import Control.Distributed.Process.Internal.Trace
  ( TraceArg(..)
  , traceFormat
  , startTracing
  , stopTracer
  )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.Messaging
  ( sendBinary
  , sendMessage
  , sendPayload
  , closeImplicitReconnections
  , impliesDeathOf
  )
import Control.Distributed.Process.Internal.Primitives
  ( register
  , finally
  , receiveWait
  , match
  , sendChan
  )
import Control.Distributed.Process.Internal.Types (SendPort)
import qualified Control.Distributed.Process.Internal.Closure.BuiltIn as BuiltIn (remoteTable)
import Control.Distributed.Process.Internal.WeakTQueue (TQueue, writeTQueue)
import qualified Control.Distributed.Process.Internal.StrictContainerAccessors as DAC
  ( mapMaybe
  , mapDefault
  )

import Unsafe.Coerce

--------------------------------------------------------------------------------
-- Initialization                                                             --
--------------------------------------------------------------------------------

initRemoteTable :: RemoteTable
initRemoteTable = BuiltIn.remoteTable Static.initRemoteTable

-- | Initialize a new local node.
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
    { _localProcesses   = Map.empty
    , _localPidCounter  = firstNonReservedProcessId
    , _localPidUnique   = unq
    , _localConnections = Map.empty
    }
  ctrlChan <- newChan
  let node = LocalNode { localNodeId   = NodeId $ NT.address endPoint
                       , localEndPoint = endPoint
                       , localState    = state
                       , localCtrlChan = ctrlChan
                       , localTracer   = InactiveTracer
                       , remoteTable   = rtable
                       }
  tracedNode <- startTracing node
  void . forkIO $ runNodeController tracedNode
  void . forkIO $ handleIncomingMessages tracedNode
  return tracedNode

-- | Start and register the service processes on a node
-- (for now, this is only the logger)
startServiceProcesses :: LocalNode -> IO ()
startServiceProcesses node = do
  logger <- forkProcess node loop
  runProcess node $ register "logger" logger
 where
  loop = do
    receiveWait
      [ match $ \((time, pid, string) ::(String, ProcessId, String)) -> do
          liftIO . hPutStrLn stderr $ time ++ " " ++ show pid ++ ": " ++ string
          loop
      , match $ \((time, string) :: (String, String)) -> do
          -- this is a 'trace' message from the local node tracer
          liftIO . hPutStrLn stderr $ time ++ " [trace] " ++ string
          loop
      , match $ \(ch :: SendPort ()) -> -- a shutdown request
          sendChan ch ()
      ]

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
  void $ forkProcess node (proc `finally` liftIO (putMVar done ()))
  takeMVar done

-- | Spawn a new process on a local node
forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess node proc = modifyMVar (localState node) startProcess
  where
    startProcess :: LocalNodeState -> IO (LocalNodeState, ProcessId)
    startProcess st = do
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
      weakQueue <- mkWeakCQueue queue (return ())
      (_, lproc) <- fixIO $ \ ~(tid, _) -> do
        let lproc = LocalProcess { processQueue  = queue
                                 , processWeakQ  = weakQueue
                                 , processId     = pid
                                 , processState  = pst
                                 , processThread = tid
                                 , processNode   = node
                                 }
        tid' <- forkIO $ do
          reason <- Exception.catch
            (runLocalProcess lproc proc >> return DiedNormal)
            (return . DiedException . (show :: SomeException -> String))

          -- [Unified: Table 4, rules termination and exiting]
          modifyMVar_ (localState node) (cleanupProcess pid)
          writeChan (localCtrlChan node) NCMsg
            { ctrlMsgSender = ProcessIdentifier pid
            , ctrlMsgSignal = Died (ProcessIdentifier pid) reason
            }
        return (tid', lproc)

      if lpidCounter lpid == maxBound
        then do
          newUnique <- randomIO
          return ( (localProcessWithId lpid ^= Just lproc)
                 . (localPidCounter ^= firstNonReservedProcessId)
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

    cleanupProcess :: ProcessId -> LocalNodeState -> IO LocalNodeState
    cleanupProcess pid st = do
      let pid' = ProcessIdentifier pid
      let (affected, unaffected) = Map.partitionWithKey (\(fr, _to) !_v -> impliesDeathOf pid' fr) (st ^. localConnections)
      mapM_ (NT.close . fst) (Map.elems affected)
      return $ (localProcessWithId (processLocalId pid) ^= Nothing)
             . (localConnections ^= unaffected)
             $ st

--------------------------------------------------------------------------------
-- Handle incoming messages                                                   --
--------------------------------------------------------------------------------

type IncomingConnection = (NT.EndPointAddress, IncomingTarget)

data IncomingTarget =
    Uninit
  | ToProc (Weak (CQueue Message))
  | ToChan TypedChannel
  | ToNode

data ConnectionState = ConnectionState {
    _incoming     :: !(Map NT.ConnectionId IncomingConnection)
  , _incomingFrom :: !(Map NT.EndPointAddress (Set NT.ConnectionId))
  }

initConnectionState :: ConnectionState
initConnectionState = ConnectionState {
    _incoming     = Map.empty
  , _incomingFrom = Map.empty
  }

incoming :: Accessor ConnectionState (Map NT.ConnectionId IncomingConnection)
incoming = accessor _incoming (\conns st -> st { _incoming = conns })

incomingAt :: NT.ConnectionId -> Accessor ConnectionState (Maybe IncomingConnection)
incomingAt cid = incoming >>> DAC.mapMaybe cid

incomingFrom :: NT.EndPointAddress -> Accessor ConnectionState (Set NT.ConnectionId)
incomingFrom addr = aux >>> DAC.mapDefault Set.empty addr
  where
    aux = accessor _incomingFrom (\fr st -> st { _incomingFrom = fr })

handleIncomingMessages :: LocalNode -> IO ()
handleIncomingMessages node = go initConnectionState
  where
    go :: ConnectionState -> IO ()
    go !st = do
      event <- NT.receive endpoint
      case event of
        NT.ConnectionOpened cid rel theirAddr ->
          if rel == NT.ReliableOrdered
            then go ( (incomingAt cid ^= Just (theirAddr, Uninit))
                    . (incomingFrom theirAddr ^: Set.insert cid)
                    $ st
                    )
            else invalidRequest cid st
        NT.Received cid payload ->
          case st ^. incomingAt cid of
            Just (_, ToProc weakQueue) -> do
              mQueue <- deRefWeak weakQueue
              forM_ mQueue $ \queue -> do
                -- TODO: if we find that the queue is Nothing, should we remove
                -- it from the NC state? (and same for channels, below)
                let msg = payloadToMessage payload
                enqueue queue msg -- 'enqueue' is strict
              go st
            Just (_, ToChan (TypedChannel chan')) -> do
              mChan <- deRefWeak chan'
              -- If mChan is Nothing, the process has given up the read end of
              -- the channel and we simply ignore the incoming message
              forM_ mChan $ \chan -> atomically $
                -- We make sure the message is fully decoded when it is enqueued
                writeTQueue chan $! decode (BSL.fromChunks payload)
              go st
            Just (_, ToNode) -> do
              let ctrlMsg = decode . BSL.fromChunks $ payload
              writeChan ctrlChan $! ctrlMsg
              go st
            Just (src, Uninit) ->
              case decode (BSL.fromChunks payload) of
                ProcessIdentifier pid -> do
                  let lpid = processLocalId pid
                  mProc <- withMVar state $ return . (^. localProcessWithId lpid)
                  case mProc of
                    Just proc ->
                      go (incomingAt cid ^= Just (src, ToProc (processWeakQ proc)) $ st)
                    Nothing ->
                      invalidRequest cid st
                SendPortIdentifier chId -> do
                  let lcid = sendPortLocalId chId
                      lpid = processLocalId (sendPortProcessId chId)
                  mProc <- withMVar state $ return . (^. localProcessWithId lpid)
                  case mProc of
                    Just proc -> do
                      mChannel <- withMVar (processState proc) $ return . (^. typedChannelWithId lcid)
                      case mChannel of
                        Just channel ->
                          go (incomingAt cid ^= Just (src, ToChan channel) $ st)
                        Nothing ->
                          invalidRequest cid st
                    Nothing ->
                      invalidRequest cid st
                NodeIdentifier nid ->
                  if nid == localNodeId node
                    then go (incomingAt cid ^= Just (src, ToNode) $ st)
                    else invalidRequest cid st
            Nothing ->
              invalidRequest cid st
        NT.ConnectionClosed cid ->
          case st ^. incomingAt cid of
            Nothing ->
              invalidRequest cid st
            Just (src, _) ->
              go ( (incomingAt cid ^= Nothing)
                 . (incomingFrom src ^: Set.delete cid)
                 $ st
                 )
        NT.ErrorEvent (NT.TransportError (NT.EventConnectionLost theirAddr) _) -> do
          -- [Unified table 9, rule node_disconnect]
          let nid = NodeIdentifier $ NodeId theirAddr
          writeChan ctrlChan NCMsg
            { ctrlMsgSender = nid
            , ctrlMsgSignal = Died nid DiedDisconnect
            }
          let notLost k = not (k `Set.member` (st ^. incomingFrom theirAddr))
          closeImplicitReconnections node nid
          go ( (incomingFrom theirAddr ^= Set.empty)
             . (incoming ^: Map.filterWithKey (const . notLost))
             $ st
             )
        NT.ErrorEvent (NT.TransportError NT.EventEndPointFailed str) ->
          fatal $ "Cloud Haskell fatal error: end point failed: " ++ str
        NT.ErrorEvent (NT.TransportError NT.EventTransportFailed str) ->
          fatal $ "Cloud Haskell fatal error: transport failed: " ++ str
        NT.EndPointClosed ->
          stopTracer (localTracer node) >> return ()
        NT.ReceivedMulticast _ _ ->
          -- If we received a multicast message, something went horribly wrong
          -- and we just give up
          fatal "Cloud Haskell fatal error: received unexpected multicast"

    fatal :: String -> IO ()
    fatal msg = stopTracer (localTracer node) >> fail msg

    invalidRequest :: NT.ConnectionId -> ConnectionState -> IO ()
    invalidRequest cid st = do
      -- TODO: We should treat this as a fatal error on the part of the remote
      -- node. That is, we should report the remote node as having died, and we
      -- should close incoming connections (this requires a Transport layer
      -- extension).
      traceEventFmtIO node "" [(TraceStr "[network] invalid request: "),
                               (Trace cid)]
      go ( incomingAt cid ^= Nothing
         $ st
         )

    state    = localState node
    endpoint = localEndPoint node
    ctrlChan = localCtrlChan node

--------------------------------------------------------------------------------
-- Top-level access to the node controller                                    --
--------------------------------------------------------------------------------

runNodeController :: LocalNode -> IO ()
runNodeController =
  runReaderT (evalStateT (unNC nodeController) initNCState)

--------------------------------------------------------------------------------
-- Internal data types                                                        --
--------------------------------------------------------------------------------

data NCState = NCState
  {  -- Mapping from remote processes to linked local processes
    _links    :: !(Map Identifier (Set ProcessId))
     -- Mapping from remote processes to monitoring local processes
  , _monitors :: !(Map Identifier (Set (ProcessId, MonitorRef)))
     -- Process registry: names and where they live, mapped to the PIDs
  , _registeredHere :: !(Map String ProcessId)
  , _registeredOnNodes :: !(Map ProcessId [(NodeId,Int)])
  }

newtype NC a = NC { unNC :: StateT NCState (ReaderT LocalNode IO) a }
  deriving (Functor, Monad, MonadIO, MonadState NCState, MonadReader LocalNode)

initNCState :: NCState
initNCState = NCState { _links    = Map.empty
                      , _monitors = Map.empty
                      , _registeredHere = Map.empty
                      , _registeredOnNodes = Map.empty
                      }

-- | Thrown in response to the user invoking 'kill' (see Primitives.hs). This
-- type is deliberately not exported so it cannot be caught explicitly.
data ProcessKillException =
    ProcessKillException !ProcessId !String
  deriving (Typeable)

instance Exception ProcessKillException
instance Show ProcessKillException where
  show (ProcessKillException pid reason) =
    "killed-by=" ++ show pid ++ ",reason=" ++ reason

--------------------------------------------------------------------------------
-- Tracing/Debugging                                                          --
--------------------------------------------------------------------------------

-- [Issue #104]

traceNotifyDied :: LocalNode -> Identifier -> DiedReason -> NC ()
traceNotifyDied node ident reason =
  case reason of
    DiedNormal -> return ()
    _ -> traceNcEventFmt node " "
                         [(TraceStr "[node-controller]"),
                          (Trace ident),
                          (Trace reason)]

traceNcEventFmt :: LocalNode -> String -> [TraceArg] -> NC ()
traceNcEventFmt node fmt args =
  liftIO $ traceEventFmtIO node fmt args

traceEventFmtIO :: LocalNode
                -> String
                -> [TraceArg]
                -> IO ()
traceEventFmtIO node fmt args =
  withLocalTracer node $ \t -> traceFormat t fmt args

withLocalTracer :: LocalNode -> (Tracer -> IO ()) -> IO ()
withLocalTracer node act = act (localTracer node)

--------------------------------------------------------------------------------
-- Core functionality                                                         --
--------------------------------------------------------------------------------

-- [Unified: Table 7]
nodeController :: NC ()
nodeController = do
  node <- ask
  forever' $ do
    msg  <- liftIO $ readChan (localCtrlChan node)

    -- [Unified: Table 7, rule nc_forward]
    case destNid (ctrlMsgSignal msg) of
      Just nid' | nid' /= localNodeId node ->
        liftIO $ sendBinary node
                            (ctrlMsgSender msg)
                            (NodeIdentifier nid')
                            WithImplicitReconnect
                            msg
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
      NCMsg (ProcessIdentifier from) (Register label atnode pid force) ->
        ncEffectRegister from label atnode pid force
      NCMsg (ProcessIdentifier from) (WhereIs label) ->
        ncEffectWhereIs from label
      NCMsg from (NamedSend label msg') ->
        ncEffectNamedSend from label msg'
      NCMsg _ (LocalSend to msg') ->
        ncEffectLocalSend to msg'
      NCMsg _ (LocalPortSend to msg') ->
        ncEffectLocalPortSend to msg'
      NCMsg (ProcessIdentifier from) (Kill to reason) ->
        ncEffectKill from to reason
      NCMsg (ProcessIdentifier from) (Exit to reason) ->
        ncEffectExit from to reason
      NCMsg (ProcessIdentifier from) (GetInfo pid) ->
        ncEffectGetInfo from pid
      unexpected ->
        error $ "nodeController: unexpected message " ++ show unexpected

-- [Unified: Table 10]
ncEffectMonitor :: ProcessId        -- ^ Who's watching?
                -> Identifier       -- ^ Who's being watched?
                -> Maybe MonitorRef -- ^ 'Nothing' to link
                -> NC ()
ncEffectMonitor from them mRef = do
  node <- ask
  shouldLink <-
    if not (isLocal node them)
      then return True
      else isValidLocalIdentifier them
  case (shouldLink, isLocal node (ProcessIdentifier from)) of
    (True, _) ->  -- [Unified: first rule]
      case mRef of
        Just ref -> modify' $ monitorsFor them ^: Set.insert (from, ref)
        Nothing  -> modify' $ linksFor them ^: Set.insert from
    (False, True) -> -- [Unified: second rule]
      notifyDied from them DiedUnknownId mRef
    (False, False) -> -- [Unified: third rule]
      -- TODO: this is the right sender according to the Unified semantics,
      -- but perhaps having 'them' as the sender would make more sense
      -- (see also: notifyDied)
      liftIO $ sendBinary node
                          (NodeIdentifier $ localNodeId node)
                          (NodeIdentifier $ processNodeId from)
                          WithImplicitReconnect
        NCMsg
          { ctrlMsgSender = NodeIdentifier (localNodeId node)
          , ctrlMsgSignal = Died them DiedUnknownId
          }

-- [Unified: Table 11]
ncEffectUnlink :: ProcessId -> Identifier -> NC ()
ncEffectUnlink from them = do
  node <- ask
  when (isLocal node (ProcessIdentifier from)) $
    case them of
      ProcessIdentifier pid ->
        postAsMessage from $ DidUnlinkProcess pid
      NodeIdentifier nid ->
        postAsMessage from $ DidUnlinkNode nid
      SendPortIdentifier cid ->
        postAsMessage from $ DidUnlinkPort cid
  modify' $ linksFor them ^: Set.delete from

-- [Unified: Table 11]
ncEffectUnmonitor :: ProcessId -> MonitorRef -> NC ()
ncEffectUnmonitor from ref = do
  node <- ask
  when (isLocal node (ProcessIdentifier from)) $
    postAsMessage from $ DidUnmonitor ref
  modify' $ monitorsFor (monitorRefIdent ref) ^: Set.delete (from, ref)

-- [Unified: Table 12]
ncEffectDied :: Identifier -> DiedReason -> NC ()
ncEffectDied ident reason = do
  node <- ask
  traceNotifyDied node ident reason
  (affectedLinks, unaffectedLinks) <- gets (splitNotif ident . (^. links))
  (affectedMons,  unaffectedMons)  <- gets (splitNotif ident . (^. monitors))

--  _registry :: !(Map (String,NodeId) ProcessId)

  let localOnly = case ident of NodeIdentifier _ -> True ; _ -> False

  forM_ (Map.toList affectedLinks) $ \(them, uss) ->
    forM_ uss $ \us ->
      when (localOnly <= isLocal node (ProcessIdentifier us)) $
        notifyDied us them reason Nothing

  forM_ (Map.toList affectedMons) $ \(them, refs) ->
    forM_ refs $ \(us, ref) ->
      when (localOnly <= isLocal node (ProcessIdentifier us)) $
        notifyDied us them reason (Just ref)

  modify' $ (links ^= unaffectedLinks) . (monitors ^= unaffectedMons)

  modify' $ registeredHere ^: Map.filter (\pid -> not $ ident `impliesDeathOf` ProcessIdentifier pid)

  remaining <- fmap Map.toList (gets (^. registeredOnNodes)) >>=
      mapM (\(pid,nidlist) ->
        case ident `impliesDeathOf` ProcessIdentifier pid of
           True ->
              do forM_ nidlist $ \(nid,_) ->
                   when (not $ isLocal node (NodeIdentifier nid))
                      (forwardNameDeath node nid)
                 return Nothing
           False -> return $ Just (pid,nidlist)  )
  modify' $ registeredOnNodes ^= (Map.fromList (catMaybes remaining))
    where
       forwardNameDeath node nid =
                   liftIO $ sendBinary node
                             (NodeIdentifier $ localNodeId node)
                             (NodeIdentifier $ nid)
                             WithImplicitReconnect
                             NCMsg
                             { ctrlMsgSender = NodeIdentifier (localNodeId node)
                             , ctrlMsgSignal = Died ident reason
                             }

-- [Unified: Table 13]
ncEffectSpawn :: ProcessId -> Closure (Process ()) -> SpawnRef -> NC ()
ncEffectSpawn pid cProc ref = do
  mProc <- unClosure cProc
  -- If the closure does not exist, we spawn a process that throws an exception
  -- This allows the remote node to find out what's happening
  let proc = case mProc of
               Left err -> fail $ "Error: Could not resolve closure: " ++ err
               Right p  -> p
  node <- ask
  pid' <- liftIO $ forkProcess node proc
  liftIO $ sendMessage node
                       (NodeIdentifier (localNodeId node))
                       (ProcessIdentifier pid)
                       WithImplicitReconnect
                       (DidSpawn ref pid')

-- Unified semantics does not explicitly describe how to implement 'register',
-- but mentions it's "very similar to nsend" (Table 14)
-- We send a response indicated if the operation is invalid
ncEffectRegister :: ProcessId -> String -> NodeId -> Maybe ProcessId -> Bool -> NC ()
ncEffectRegister from label atnode mPid reregistration = do
  node <- ask
  currentVal <- gets (^. registeredHereFor label)
  isOk <-
       case mPid of
         Nothing -> -- unregister request
           return $ isJust currentVal
         Just thepid -> -- register request
           do isvalidlocal <- isValidLocalIdentifier (ProcessIdentifier thepid)
              return $ (isNothing currentVal /= reregistration) &&
                (not (isLocal node (ProcessIdentifier thepid) ) || isvalidlocal )
  if isLocal node (NodeIdentifier atnode)
     then do when (isOk) $
               do modify' $ registeredHereFor label ^= mPid
                  updateRemote node currentVal mPid
             liftIO $ sendMessage node
                       (NodeIdentifier (localNodeId node))
                       (ProcessIdentifier from)
                       WithImplicitReconnect
                       (RegisterReply label isOk)
     else let operation =
                 case reregistration of
                    True -> flip decList
                    False -> flip incList
           in case mPid of
                Nothing -> return ()
                Just pid -> modify' $ registeredOnNodesFor pid ^: (maybeify $ operation atnode)
      where updateRemote node (Just oldval) (Just newval) | processNodeId oldval /= processNodeId newval =
              do forward node (processNodeId oldval) (Register label atnode (Just oldval) True)
                 forward node (processNodeId newval) (Register label atnode (Just newval) False)
            updateRemote node Nothing (Just newval) =
                 forward node (processNodeId newval) (Register label atnode (Just newval) False)
            updateRemote node (Just oldval) Nothing =
                 forward node (processNodeId oldval) (Register label atnode (Just oldval) True)
            updateRemote _ _ _ = return ()
            maybeify f Nothing = unmaybeify $ f []
            maybeify f (Just x) = unmaybeify $ f x
            unmaybeify [] = Nothing
            unmaybeify x = Just x
            incList [] tag = [(tag,1)]
            incList ((atag,acount):xs) tag | tag==atag = (atag,acount+1) : xs
            incList (x:xs) tag = x : incList xs tag
            decList [] _ = []
            decList ((atag,1):xs) tag | atag == tag = xs
            decList ((atag,n):xs) tag | atag == tag = (atag,n-1):xs
            decList (x:xs) tag = x:decList xs tag
            forward node to reg =
              when (not $ isLocal node (NodeIdentifier to)) $
                    liftIO $ sendBinary node
                                        (ProcessIdentifier from)
                                        (NodeIdentifier to)
                                        WithImplicitReconnect
                                        NCMsg
                                         { ctrlMsgSender = ProcessIdentifier from
                                         , ctrlMsgSignal = reg
                                         }


-- Unified semantics does not explicitly describe 'whereis'
ncEffectWhereIs :: ProcessId -> String -> NC ()
ncEffectWhereIs from label = do
  node <- ask
  mPid <- gets (^. registeredHereFor label)
  liftIO $ sendMessage node
                       (NodeIdentifier (localNodeId node))
                       (ProcessIdentifier from)
                       WithImplicitReconnect
                       (WhereIsReply label mPid)

-- [Unified: Table 14]
ncEffectNamedSend :: Identifier -> String -> Message -> NC ()
ncEffectNamedSend from label msg = do
  node <- ask
  mPid <- gets (^. registeredHereFor label)
  -- If mPid is Nothing, we just ignore the named send (as per Table 14)
  forM_ mPid $ \pid ->
    liftIO $ sendPayload node
                         from
                         (ProcessIdentifier pid)
                         NoImplicitReconnect
                         (messageToPayload msg)

-- [Issue #DP-20]
ncEffectLocalSend :: ProcessId -> Message -> NC ()
ncEffectLocalSend = postMessage

-- [Issue #DP-20]
ncEffectLocalPortSend :: SendPortId -> Message -> NC ()
ncEffectLocalPortSend from msg =
  let pid = sendPortProcessId from
      cid = sendPortLocalId   from
  in do
  withLocalProc pid $ \proc -> do
    mChan <- withMVar (processState proc) $ return . (^. typedChannelWithId cid)
    case mChan of
      -- in the unlikely event we know nothing about this channel id,
      -- there's little to be done - perhaps some logging/tracing though...
      Nothing -> return ()
      Just (TypedChannel chan') -> do
        -- If ch is Nothing, the process has given up the read end of
        -- the channel and we simply ignore the incoming message - this
        ch <- deRefWeak chan'
        forM_ ch $ \chan -> deliverChan msg chan
  where deliverChan :: forall a . Message -> TQueue a -> IO ()
        deliverChan (UnencodedMessage _ raw) chan' =
            atomically $ writeTQueue chan' ((unsafeCoerce raw) :: a)
        deliverChan (EncodedMessage   _ _) _ =
            -- this will not happen unless someone screws with Primitives.hs
            error "invalid local channel delivery"

-- [Issue #69]
ncEffectKill :: ProcessId -> ProcessId -> String -> NC ()
ncEffectKill from to reason = do
  node <- ask
  when (isLocal node (ProcessIdentifier to)) $
    throwException to $ ProcessKillException from reason

-- [Issue #69]
ncEffectExit :: ProcessId -> ProcessId -> Message -> NC ()
ncEffectExit from to reason = do
  node <- ask
  when (isLocal node (ProcessIdentifier to)) $
    throwException to $ ProcessExitException from reason

-- [Issue #89]
ncEffectGetInfo :: ProcessId -> ProcessId -> NC ()
ncEffectGetInfo from pid =
  let lpid = processLocalId pid
      them = (ProcessIdentifier pid)
  in do
  node <- ask
  mProc <- liftIO $
            withMVar (localState node) $ return . (^. localProcessWithId lpid)
  case mProc of
    Nothing   -> dispatch (isLocal node (ProcessIdentifier from))
                          from node (ProcessInfoNone DiedUnknownId)
    Just _    -> do
      itsLinks    <- gets (^. linksFor    them)
      itsMons     <- gets (^. monitorsFor them)
      registered  <- gets (^. registeredHere)

      let reg = registeredNames registered
      dispatch (isLocal node (ProcessIdentifier from))
               from
               node
               ProcessInfo {
                   infoNode               = (processNodeId pid)
                 , infoRegisteredNames    = reg
                   -- we cannot populate this field
                 , infoMessageQueueLength = Nothing
                 , infoMonitors       = Set.toList itsMons
                 , infoLinks          = Set.toList itsLinks
                 }
  where dispatch :: (Serializable a, Show a)
                 => Bool
                 -> ProcessId
                 -> LocalNode
                 -> a
                 -> NC ()
        dispatch True  dest _    pInfo = postAsMessage dest $ pInfo
        dispatch False dest node pInfo = do
            liftIO $ sendMessage node
                                 (NodeIdentifier (localNodeId node))
                                 (ProcessIdentifier dest)
                                 WithImplicitReconnect
                                 pInfo

        registeredNames = Map.foldlWithKey (\ks k v -> if v == pid
                                                 then (k:ks)
                                                 else ks) []

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

notifyDied :: ProcessId         -- ^ Who to notify?
           -> Identifier        -- ^ Who died?
           -> DiedReason        -- ^ How did they die?
           -> Maybe MonitorRef  -- ^ 'Nothing' for linking
           -> NC ()
notifyDied dest src reason mRef = do
  node <- ask
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
      -- The change in sender comes from [Unified: Table 10]
      liftIO $ sendBinary node
                          (NodeIdentifier $ localNodeId node)
                          (NodeIdentifier $ processNodeId dest)
                          WithImplicitReconnect
        NCMsg
          { ctrlMsgSender = NodeIdentifier (localNodeId node)
          , ctrlMsgSignal = Died src reason
          }

-- | [Unified: Table 8]
destNid :: ProcessSignal -> Maybe NodeId
destNid (Link ident)          = Just $ nodeOf ident
destNid (Unlink ident)        = Just $ nodeOf ident
destNid (Monitor ref)         = Just $ nodeOf (monitorRefIdent ref)
destNid (Unmonitor ref)       = Just $ nodeOf (monitorRefIdent ref)
destNid (Spawn _ _)           = Nothing
destNid (Register _ _ _ _)    = Nothing
destNid (WhereIs _)           = Nothing
destNid (NamedSend _ _)       = Nothing
-- We don't need to forward 'Died' signals; if monitoring/linking is setup,
-- then when a local process dies the monitoring/linking machinery will take
-- care of notifying remote nodes
destNid (Died _ _)            = Nothing
destNid (Kill pid _)          = Just $ processNodeId pid
destNid (Exit pid _)          = Just $ processNodeId pid
destNid (GetInfo pid)         = Just $ processNodeId pid
destNid (LocalSend pid _)     = Just $ processNodeId pid
destNid (LocalPortSend cid _) = Just $ processNodeId (sendPortProcessId cid)

-- | Check if a process is local to our own node
isLocal :: LocalNode -> Identifier -> Bool
isLocal nid ident = nodeOf ident == localNodeId nid

-- | Lookup a local closure
unClosure :: Typeable a => Closure a -> NC (Either String a)
unClosure closure = do
  rtable <- remoteTable <$> ask
  return (Static.unclosure rtable closure)

-- | Check if an identifier refers to a valid local object
isValidLocalIdentifier :: Identifier -> NC Bool
isValidLocalIdentifier ident = do
  node <- ask
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
postAsMessage pid = postMessage pid . createUnencodedMessage

postMessage :: ProcessId -> Message -> NC ()
postMessage pid msg = do
  withLocalProc pid $ \p -> enqueue (processQueue p) msg

throwException :: Exception e => ProcessId -> e -> NC ()
throwException pid e = withLocalProc pid $ \p ->
  throwTo (processThread p) e

withLocalProc :: ProcessId -> (LocalProcess -> IO ()) -> NC ()
withLocalProc pid p = do
  node <- ask
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

registeredHere :: Accessor NCState (Map String ProcessId)
registeredHere = accessor _registeredHere (\ry st -> st { _registeredHere = ry })

registeredOnNodes :: Accessor NCState (Map ProcessId [(NodeId, Int)])
registeredOnNodes = accessor _registeredOnNodes (\ry st -> st { _registeredOnNodes = ry })

linksFor :: Identifier -> Accessor NCState (Set ProcessId)
linksFor ident = links >>> DAC.mapDefault Set.empty ident

monitorsFor :: Identifier -> Accessor NCState (Set (ProcessId, MonitorRef))
monitorsFor ident = monitors >>> DAC.mapDefault Set.empty ident

registeredHereFor :: String -> Accessor NCState (Maybe ProcessId)
registeredHereFor ident = registeredHere >>> DAC.mapMaybe ident

registeredOnNodesFor :: ProcessId -> Accessor NCState (Maybe [(NodeId,Int)])
registeredOnNodesFor ident = registeredOnNodes >>> DAC.mapMaybe ident

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
--
-- See https://github.com/haskell/containers/issues/14 for the bang on _v.
splitNotif :: Identifier
           -> Map Identifier a
           -> (Map Identifier a, Map Identifier a)
splitNotif ident = Map.partitionWithKey (\k !_v -> ident `impliesDeathOf` k)

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

-- | Modify and evaluate the state
modify' :: MonadState s m => (s -> s) -> m ()
modify' f = StateT.get >>= \s -> StateT.put $! f s
