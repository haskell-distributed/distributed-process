module Control.Distributed.Process.Internal.Node 
  ( -- * Message sending
    sendPayload
  , sendBinary
  , sendMessage
  , reconnect
  ) where

import Data.Accessor ((^.), (^=))
import Data.Binary (Binary, encode)
import qualified Data.ByteString.Lazy as BSL (toChunks)
import qualified Data.ByteString as BSS (ByteString)
import Control.Distributed.Process.Internal.StrictMVar (withMVar, modifyMVar_)
import Control.Concurrent.Chan (writeChan)
import Control.Monad (unless)
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
  , localConnectionBetween
  , nodeAddress
  , nodeOf
  , messageToPayload
  , createMessage
  , NCMsg(..)
  , ProcessSignal(Died)
  , DiedReason(DiedDisconnect)
  )
import Control.Distributed.Process.Serializable (Serializable)

--------------------------------------------------------------------------------
-- Message sending                                                            -- 
--------------------------------------------------------------------------------

sendPayload :: LocalNode -> Identifier -> Identifier -> [BSS.ByteString] -> IO ()
sendPayload node from to payload = do
  mConn <- connBetween node from to
  didSend <- case mConn of
    Just conn -> do
      didSend <- NT.send conn payload
      case didSend of
        Left _err -> return False 
        Right ()  -> return True 
    Nothing -> return False
  unless didSend $
    writeChan (localCtrlChan node) NCMsg
      { ctrlMsgSender = to 
      , ctrlMsgSignal = Died to DiedDisconnect
      }

sendBinary :: Binary a => LocalNode -> Identifier -> Identifier -> a -> IO ()
sendBinary node from to = sendPayload node from to . BSL.toChunks . encode

sendMessage :: Serializable a => LocalNode -> Identifier -> Identifier -> a -> IO ()
sendMessage node from to = sendPayload node from to . messageToPayload . createMessage

setupConnBetween :: LocalNode -> Identifier -> Identifier -> IO (Maybe NT.Connection)
setupConnBetween node from to = do
    mConn    <- NT.connect endPoint 
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
              (localConnectionBetween from to ^= Just conn)
            return $ Just conn
      Left _ ->
        return Nothing
  where
    endPoint  = localEndPoint node
    nodeState = localState node

connBetween :: LocalNode -> Identifier -> Identifier -> IO (Maybe NT.Connection)
connBetween node from to = do
    mConn <- withMVar nodeState $ return . (^. localConnectionBetween from to)
    case mConn of
      Just conn -> return $ Just conn
      Nothing   -> setupConnBetween node from to 
  where
    nodeState = localState node

reconnect :: LocalNode -> Identifier -> Identifier -> IO ()
reconnect node from to =
  modifyMVar_ (localState node) $ \st -> 
    case st ^. localConnectionBetween from to of
      Nothing -> 
        return st
      Just conn -> do
        NT.close conn 
        return (localConnectionBetween from to ^= Nothing $ st)
