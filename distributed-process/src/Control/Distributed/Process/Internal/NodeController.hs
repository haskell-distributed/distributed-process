module Control.Distributed.Process.Internal.NodeController 
  ( runNodeController
  , NCMsg(..)
  ) where

import Data.Map (Map)
import qualified Data.Map as Map (empty, toList)
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert, delete)
import Data.Foldable (forM_)
import Data.Maybe (isJust)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapDefault)
import Control.Category ((>>>))
import Control.Monad (when, forever)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State (MonadState, StateT, evalStateT, gets, modify)
import qualified Control.Monad.Trans.Class as Trans (lift)
import Control.Concurrent.MVar (withMVar)
import Control.Concurrent.Chan (readChan)
import Control.Exception (Exception, throwTo)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal.Types
  ( NodeId(..)
  , LocalProcessId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , MonitorRef(..)
  , MonitorNotification(..)
  , LinkException(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
  , DiedReason(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , createMessage
  , localProcessWithId
  , MessageT
  , runMessageT
  )
import Control.Distributed.Process.Internal.MessageT 
  ( sendBinary
  , getLocalNode
  )

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
      Just nid' | nid' /= localNodeId node -> lift $ sendBinary (Right nid') msg
      _ -> return ()

    case msg of
      NCMsg (Left from) (Link them) ->
        ncEffectMonitor from them Nothing
      NCMsg (Left from) (Monitor them ref) ->
        ncEffectMonitor from them (Just ref)
      NCMsg (Left from) (Unlink them) ->
        ncEffectUnlink from them 
      NCMsg (Left from) (Unmonitor ref) ->
        ncEffectUnmonitor from ref
      NCMsg _from (Died (Right nid) reason) ->
        ncEffectNodeDied nid reason
      NCMsg _from (Died (Left pid) reason) ->
        ncEffectProcessDied pid reason
      NCMsg _from (Spawn _ _) ->
        fail $ show (localNodeId node) ++ ": spawn not implemented"
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
      lift $ sendBinary (Right $ processNodeId from) NCMsg 
        { ctrlMsgSender = Right (localNodeId node)
        , ctrlMsgSignal = Died (Left them) DiedNoProc
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
      lift $ sendBinary (Right $ processNodeId dest) NCMsg
        { ctrlMsgSender = Right (localNodeId node) 
        , ctrlMsgSignal = Died (Left src) reason
        }
      
-- | [Unified: Table 8]
destNid :: ProcessSignal -> Maybe NodeId
destNid (Link pid)           = Just . processNodeId $ pid
destNid (Unlink pid)         = Just . processNodeId $ pid
destNid (Monitor pid _)      = Just . processNodeId $ pid 
destNid (Unmonitor ref)      = Just . processNodeId . monitorRefPid $ ref 
destNid (Died (Right _) _)   = Nothing
destNid (Died (Left _pid) _) = fail "destNid: TODO"
destNid (Spawn _ _)          = Nothing

-- | Check if a process is local to our own node
isLocal :: LocalNode -> ProcessId -> Bool 
isLocal nid pid = processNodeId pid == localNodeId nid 

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
