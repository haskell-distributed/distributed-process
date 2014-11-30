module Control.Distributed.Process.Internal.Messaging
  ( sendPayload
  , sendBinary
  , sendMessage
  , disconnect
  , closeImplicitReconnections
  , impliesDeathOf
  , sendCtrlMsg
  ) where

import Data.Accessor ((^.), (^=))
import Data.Binary (Binary, encode)
import qualified Data.Map as Map (partitionWithKey, elems)
import qualified Data.ByteString.Lazy as BSL (toChunks)
import qualified Data.ByteString as BSS (ByteString)
import Control.Distributed.Process.Internal.StrictMVar (withMVar, modifyMVar_)
import Control.Distributed.Process.Serializable ()

import Control.Concurrent.Chan (writeChan)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import qualified Network.Transport as NT
  ( Connection
  , send
  , defaultConnectHints
  , connect
  , Reliability(ReliableOrdered)
  , close
  )
import Control.Distributed.Process.Internal.Types
  ( LocalNode(localState, localEndPoint, localCtrlChan)
  , Identifier
  , localConnections
  , localConnectionBetween
  , nodeAddress
  , nodeOf
  , messageToPayload
  , createMessage
  , NCMsg(..)
  , ProcessSignal(Died)
  , DiedReason(DiedDisconnect)
  , ImplicitReconnect(WithImplicitReconnect)
  , NodeId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , SendPortId(sendPortProcessId)
  , Identifier(NodeIdentifier, ProcessIdentifier, SendPortIdentifier)
  )
import Control.Distributed.Process.Serializable (Serializable)

--------------------------------------------------------------------------------
-- Message sending                                                            --
--------------------------------------------------------------------------------

sendPayload :: LocalNode
            -> Identifier
            -> Identifier
            -> ImplicitReconnect
            -> [BSS.ByteString]
            -> IO ()
sendPayload node from to implicitReconnect payload = do
  mConn <- connBetween node from to implicitReconnect
  didSend <- case mConn of
    Just conn -> do
      didSend <- NT.send conn payload
      case didSend of
        Left _err -> return False
        Right ()  -> return True
    Nothing -> return False
  unless didSend $ do
    writeChan (localCtrlChan node) NCMsg
      { ctrlMsgSender = to
      , ctrlMsgSignal = Died to DiedDisconnect
      }

sendBinary :: Binary a
           => LocalNode
           -> Identifier
           -> Identifier
           -> ImplicitReconnect
           -> a
           -> IO ()
sendBinary node from to implicitReconnect
  = sendPayload node from to implicitReconnect . BSL.toChunks . encode

sendMessage :: Serializable a
            => LocalNode
            -> Identifier
            -> Identifier
            -> ImplicitReconnect
            -> a
            -> IO ()
sendMessage node from to implicitReconnect =
  sendPayload node from to implicitReconnect . messageToPayload . createMessage

setupConnBetween :: LocalNode
                 -> Identifier
                 -> Identifier
                 -> ImplicitReconnect
                 -> IO (Maybe NT.Connection)
setupConnBetween node from to implicitReconnect = do
    mConn <- NT.connect endPoint
                        (nodeAddress . nodeOf $ to)
                        NT.ReliableOrdered
                        NT.defaultConnectHints
    case mConn of
      Right conn -> do
        didSend <- NT.send conn (BSL.toChunks . encode $ to)
        case didSend of
          Left _ ->
            return Nothing
          Right () -> do
            modifyMVar_ nodeState $ return .
              (localConnectionBetween from to ^= Just (conn, implicitReconnect))
            return $ Just conn
      Left _ ->
        return Nothing
  where
    endPoint  = localEndPoint node
    nodeState = localState node

connBetween :: LocalNode
            -> Identifier
            -> Identifier
            -> ImplicitReconnect
            -> IO (Maybe NT.Connection)
connBetween node from to implicitReconnect = do
    mConn <- withMVar nodeState $ return . (^. localConnectionBetween from to)
    case mConn of
      Just (conn, _) ->
        return $ Just conn
      Nothing ->
        setupConnBetween node from to implicitReconnect
  where
    nodeState = localState node

disconnect :: LocalNode -> Identifier -> Identifier -> IO ()
disconnect node from to =
  modifyMVar_ (localState node) $ \st ->
    case st ^. localConnectionBetween from to of
      Nothing ->
        return st
      Just (conn, _) -> do
        NT.close conn
        return (localConnectionBetween from to ^= Nothing $ st)

closeImplicitReconnections :: LocalNode -> Identifier -> IO ()
closeImplicitReconnections node to =
  modifyMVar_ (localState node) $ \st -> do
    let shouldClose (_, to') (_, WithImplicitReconnect) = to `impliesDeathOf` to'
        shouldClose _ _ = False
    let (affected, unaffected) = Map.partitionWithKey shouldClose (st ^. localConnections)
    mapM_ (NT.close . fst) (Map.elems affected)
    return (localConnections ^= unaffected $ st)

-- | @a `impliesDeathOf` b@ is true if the death of @a@ (for instance, a node)
-- implies the death of @b@ (for instance, a process on that node)
impliesDeathOf :: Identifier
               -> Identifier
               -> Bool
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
      liftIO $ writeChan (localCtrlChan (processNode proc)) msg
    Just nid ->
      liftIO $ sendBinary (processNode proc)
                          (ProcessIdentifier (processId proc))
                          (NodeIdentifier nid)
                          WithImplicitReconnect
                          msg
