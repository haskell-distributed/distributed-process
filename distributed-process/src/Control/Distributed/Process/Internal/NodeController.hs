module Control.Distributed.Process.Internal.NodeController 
  ( runNodeController
  , NCMsg(..)
  ) where

import Data.Map (Map)
import qualified Data.Map as Map (empty, toList)
import Data.Set (Set)
import qualified Data.Set as Set (empty, insert)
import qualified Data.ByteString as BSS (ByteString)
import qualified Data.ByteString.Lazy as BSL (toChunks)
import Data.Binary (encode)
import Data.Foldable (forM_)
import Data.Maybe (isJust)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe, mapDefault)
import Control.Category ((>>>))
import Control.Monad (when, unless, forever)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State (MonadState, StateT, evalStateT, gets, modify)
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Concurrent.MVar (withMVar)
import Control.Concurrent.Chan (readChan, writeChan)
import qualified Network.Transport as NT ( EndPoint
                                         , Connection
                                         , Reliability(ReliableOrdered)
                                         , defaultConnectHints
                                         , send
                                         , connect
                                         )
import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal ( NodeId(..)
                                            , LocalProcessId(..)
                                            , ProcessId(..)
                                            , LocalNode(..)
                                            , LocalProcess(..)
                                            , Message(..)
                                            , MonitorRef
                                            , MonitorReply(..)
                                            , DiedReason(..)
                                            , Identifier
                                            , NCMsg(..)
                                            , ProcessSignal(..)
                                            , createMessage
                                            , idToPayload
                                            , localProcessWithId
                                            )

--------------------------------------------------------------------------------
-- Top-level access to the node controller                                    --
--------------------------------------------------------------------------------

runNodeController :: LocalNode -> IO ()
runNodeController node = 
  evalStateT (runReaderT (unNC nodeController) node) initNCState


data NCState = NCState 
  {  -- Mapping from remote processes to linked local processes 
    _ncLinks :: Map NodeId (Map LocalProcessId (Set ProcessId))
     -- Mapping from remote processes to monitoring local processes
  , _ncMons  :: Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
     -- The node controller maintains its own set of connections
     -- TODO: still not convinced that this is correct
  , _ncConns :: Map Identifier NT.Connection 
  }

destNid :: ProcessSignal -> Maybe NodeId
destNid (Monitor pid _)      = Just $ processNodeId pid 
destNid (Died (Right _) _)   = Nothing
destNid (Died (Left _pid) _) = fail "destNid: TODO"

initNCState :: NCState
initNCState = NCState
  { _ncLinks = Map.empty
  , _ncMons  = Map.empty
  , _ncConns = Map.empty 
  }

newtype NC a = NC { unNC :: ReaderT LocalNode (StateT NCState IO) a }
  deriving (Functor, Monad, MonadIO, MonadState NCState, MonadReader LocalNode)

nodeController :: NC ()
nodeController = forever $ do
  node <- ask
  msg  <- liftIO $ readChan (localCtrlChan node)

  -- Forward the message if appropriate
  case destNid (ctrlMsgSignal msg) of
    Just nid' | nid' /= localNodeId node -> ncSendCtrlMsg nid' msg
    _ -> return ()

  ncEffect msg

ctrlSendTo :: Identifier -> [BSS.ByteString] -> NC () 
ctrlSendTo them payload = do
  mConn <- ncConnTo them
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
    liftIO . writeChan (localCtrlChan node) $ NCMsg 
      { ctrlMsgSender = them 
      , ctrlMsgSignal = Died them DiedDisconnect
      }

ncSendCtrlMsg :: NodeId -> NCMsg -> NC ()
ncSendCtrlMsg dest = ctrlSendTo (Right dest) . BSL.toChunks . encode 

ncSendLocal :: LocalProcessId -> Message -> NC ()
ncSendLocal lpid msg = do
  node <- ask
  liftIO $ do
    mProc <- withMVar (localState node) $ return . (^. localProcessWithId lpid)
    -- By [Unified: table 6, rule missing_process] messages to dead processes
    -- can silently be dropped
    forM_ mProc $ \proc -> enqueue (processQueue proc) msg 

ncConnTo :: Identifier -> NC (Maybe NT.Connection)
ncConnTo them = do
  mConn <- gets (^. ncConnFor them)
  case mConn of
    Just conn -> return (Just conn)
    Nothing   -> ncCreateConnTo them

ncCreateConnTo :: Identifier -> NC (Maybe NT.Connection)
ncCreateConnTo them = do
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
            modify $ ncConnFor them ^= Just conn
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
ncEffect :: NCMsg -> NC ()

-- [Unified: Table 10]
ncEffect (NCMsg (Left from) (Monitor them ref)) = do
  node <- ask 
  shouldLink <- 
    if processNodeId them /= localNodeId node 
      then return True
      else liftIO . withMVar (localState node) $ 
        return . isJust . (^. localProcessWithId (processLocalId them))
  let localFrom = processNodeId from == localNodeId node
  case (shouldLink, localFrom) of
    (True, _) ->  -- [Unified: first rule]
      modify $ ncMonsFor them from ^: Set.insert ref
    (False, True) -> -- [Unified: second rule]
      ncSendLocal (processLocalId from) . createMessage $
        ProcessDied ref them DiedNoProc 
    (False, False) -> -- [Unified: third rule]
      ncSendCtrlMsg (processNodeId from) NCMsg 
        { ctrlMsgSender = Right (localNodeId node)
        , ctrlMsgSignal = Died (Left them) DiedNoProc
        }
      
ncEffect (NCMsg (Right _) (Monitor _ _)) = 
  error "Monitor message from a node?"

-- [Unified: Table 12, bottom rule] 
ncEffect (NCMsg _from (Died (Right nid) reason)) = do
  node  <- ask
  links <- gets (^. ncLinksForNode nid)
  mons  <- gets (^. ncMonsForNode nid)

  forM_ (Map.toList links) $ \(_them, _uss) -> 
    fail "ncEffect: linking not implemented"

  forM_ (Map.toList mons) $ \(them, uss) ->
    forM_ (Map.toList uss) $ \(us, refs) -> 
      -- We only need to notify local processes
      when (processNodeId us == localNodeId node) $ do
        let lpid = processLocalId us
            rpid = ProcessId nid them 
        forM_ refs $ \ref -> 
          ncSendLocal lpid . createMessage $ ProcessDied ref rpid reason

  modify $ (ncLinksForNode nid ^= Map.empty)
         . (ncMonsForNode nid ^= Map.empty)

-- [Unified: Table 12, top rule]
ncEffect (NCMsg _from (Died (Left pid) reason)) = do
  node  <- ask
  links <- gets (^. ncLinksForProcess pid)
  mons  <- gets (^. ncMonsForProcess pid)

  forM_ links $ \_us ->
    fail "ncEffect: linking not implemented"

  forM_ (Map.toList mons) $ \(us, refs) ->
    forM_ refs $ \ref -> do
      let msg = createMessage $ ProcessDied ref pid reason
      if processNodeId us == localNodeId node 
        then 
          ncSendLocal (processLocalId us) msg
        else 
          ncSendCtrlMsg (processNodeId us) NCMsg
            { ctrlMsgSender = Right (localNodeId node) -- TODO: why the change in sender? How does that affect 'reconnect' semantics?
            , ctrlMsgSignal = Died (Left pid) reason
            }

  modify $ (ncLinksForProcess pid ^= Set.empty)
         . (ncMonsForProcess pid ^= Map.empty)

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

ncLinks :: Accessor NCState (Map NodeId (Map LocalProcessId (Set ProcessId)))
ncLinks = accessor _ncLinks (\links st -> st { _ncLinks = links })

ncMons :: Accessor NCState (Map NodeId (Map LocalProcessId (Map ProcessId (Set MonitorRef))))
ncMons = accessor _ncMons (\mons st -> st { _ncMons = mons })

ncConns :: Accessor NCState (Map Identifier NT.Connection)
ncConns = accessor _ncConns (\conns st -> st { _ncConns = conns })

ncConnFor :: Identifier -> Accessor NCState (Maybe NT.Connection)
ncConnFor them = ncConns >>> DAC.mapMaybe them 

ncLinksForNode :: NodeId -> Accessor NCState (Map LocalProcessId (Set ProcessId))
ncLinksForNode nid = ncLinks >>> DAC.mapDefault Map.empty nid 

ncMonsForNode :: NodeId -> Accessor NCState (Map LocalProcessId (Map ProcessId (Set MonitorRef)))
ncMonsForNode nid = ncMons >>> DAC.mapDefault Map.empty nid 

ncLinksForProcess :: ProcessId -> Accessor NCState (Set ProcessId)
ncLinksForProcess pid = ncLinksForNode (processNodeId pid) >>> DAC.mapDefault Set.empty (processLocalId pid)

ncMonsForProcess :: ProcessId -> Accessor NCState (Map ProcessId (Set MonitorRef))
ncMonsForProcess pid = ncMonsForNode (processNodeId pid) >>> DAC.mapDefault Map.empty (processLocalId pid) 

ncMonsFor :: ProcessId -> ProcessId -> Accessor NCState (Set MonitorRef)
ncMonsFor them us = ncMonsForProcess them >>> DAC.mapDefault Set.empty us 
