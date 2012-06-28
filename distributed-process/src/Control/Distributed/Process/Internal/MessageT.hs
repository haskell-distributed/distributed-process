-- | Add message sending capability to a monad
-- 
-- NOTE: Not thread-safe (you should not do concurrent sends within the same
-- monad).
module Control.Distributed.Process.Internal.MessageT 
  ( MessageT
  , runMessageT
  , getLocalNode
  , sendPayload
  , sendBinary
  , sendMessage
  , payloadToMessage
  , createMessage
  ) where

import Data.Binary (Binary, encode)
import qualified Data.ByteString as BSS (ByteString, concat)
import qualified Data.ByteString.Lazy as BSL (toChunks, fromChunks, splitAt)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Accessor (Accessor, accessor, (^=), (^.))
import qualified Data.Accessor.Container as DAC (mapMaybe)
import Control.Category ((>>>))
import Control.Monad (unless, liftM)
import Control.Monad.State (gets, modify, evalStateT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent.Chan (writeChan)
import Control.Distributed.Process.Internal.Types
  ( Identifier(..)
  , NodeId(nodeAddress) 
  , ProcessId(processNodeId)
  , ChannelId(channelProcessId)
  , LocalNode(localCtrlChan, localEndPoint)
  , NCMsg(NCMsg, ctrlMsgSender, ctrlMsgSignal)
  , DiedReason(DiedDisconnect)
  , ProcessSignal(Died)
  , Message(..)
  , MessageT(..)
  , MessageState(..)
  )
import Control.Distributed.Process.Serializable 
  ( Serializable
  , fingerprint
  , encodeFingerprint
  , decodeFingerprint
  , sizeOfFingerprint
  )  
import qualified Network.Transport as NT 
  ( EndPoint 
  , Connection
  , connect
  , send
  , Reliability(ReliableOrdered)
  , defaultConnectHints
  )

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

runMessageT :: Monad m => LocalNode -> MessageT m a -> m a
runMessageT localNode m = 
  evalStateT (unMessageT m) $ initMessageState localNode 

getLocalNode :: Monad m => MessageT m LocalNode
getLocalNode = gets messageLocalNode

sendPayload :: MonadIO m => Identifier -> [BSS.ByteString] -> MessageT m ()
sendPayload them payload = do
  mConn <- connTo them
  didSend <- case mConn of
    Just conn -> do
      didSend <- liftIO $ NT.send conn payload
      case didSend of
        Left _  -> return False
        Right _ -> return True 
    Nothing -> return False
  unless didSend $ do
    node <- getLocalNode
    liftIO . writeChan (localCtrlChan node) $ NCMsg
      { ctrlMsgSender = them
      , ctrlMsgSignal = Died them DiedDisconnect
      }

sendBinary :: (MonadIO m, Binary a) => Identifier -> a -> MessageT m ()
sendBinary them = sendPayload them . BSL.toChunks . encode

sendMessage :: (MonadIO m, Serializable a) => Identifier -> a -> MessageT m ()
sendMessage them = sendPayload them . messageToPayload . createMessage

--------------------------------------------------------------------------------
-- Serialization/deserialization                                              --
--------------------------------------------------------------------------------

-- | Turn any serialiable term into a message
createMessage :: Serializable a => a -> Message
createMessage a = Message (fingerprint a) (encode a)

-- | Serialize a message
messageToPayload :: Message -> [BSS.ByteString]
messageToPayload (Message fp enc) = encodeFingerprint fp : BSL.toChunks enc

-- | Deserialize a message
payloadToMessage :: [BSS.ByteString] -> Message
payloadToMessage payload = Message fp msg
  where
    (encFp, msg) = BSL.splitAt (fromIntegral sizeOfFingerprint) 
                 $ BSL.fromChunks payload 
    fp = decodeFingerprint . BSS.concat . BSL.toChunks $ encFp

--------------------------------------------------------------------------------
-- Internal                                                                   --
--------------------------------------------------------------------------------

initMessageState :: LocalNode -> MessageState
initMessageState localNode = MessageState {
     messageLocalNode   = localNode 
  , _messageConnections = Map.empty
  }

setupConnTo :: MonadIO m => Identifier -> MessageT m (Maybe NT.Connection)
setupConnTo them = do
    endPoint <- localEndPoint `liftM` getLocalNode 
    mConn    <- liftIO $ NT.connect endPoint 
                                    (nodeAddress . identifierNode $ them) 
                                    NT.ReliableOrdered 
                                    NT.defaultConnectHints
    case mConn of 
      Right conn -> do
        didSend <- liftIO $ NT.send conn (BSL.toChunks . encode $ them)
        case didSend of
          Left _ ->
            return Nothing
          Right () -> do
            modify $ messageConnectionTo them ^= Just conn
            return $ Just conn
      Left _ ->
        return Nothing

connTo :: MonadIO m => Identifier -> MessageT m (Maybe NT.Connection)
connTo them = do
  mConn <- gets (^. messageConnectionTo them)
  case mConn of
    Just conn -> return $ Just conn
    Nothing   -> setupConnTo them

identifierNode :: Identifier -> NodeId
identifierNode (NodeIdentifier nid)    = nid
identifierNode (ProcessIdentifier pid) = processNodeId pid
identifierNode (ChannelIdentifier cid) = processNodeId (channelProcessId cid)

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

messageConnections :: Accessor MessageState (Map Identifier NT.Connection)
messageConnections = accessor _messageConnections (\conns st -> st { _messageConnections = conns })

messageConnectionTo :: Identifier -> Accessor MessageState (Maybe NT.Connection)
messageConnectionTo them = messageConnections >>> DAC.mapMaybe them
