module Control.Distributed.Process.Internal.Messaging
  ( -- * Message sending
    ImplicitReconnect(WithImplicitReconnect, NoImplicitReconnect)
  , sendPayload
  , sendBinary
  , sendMessage
  , disconnect 
  ) where

import Data.Accessor ((^.), (^=))
import Data.Binary (Binary, encode)
import qualified Data.ByteString.Lazy as BSL (toChunks)
import qualified Data.ByteString as BSS (ByteString)
import Control.Distributed.Process.Internal.StrictMVar (withMVar, modifyMVar_)
import Control.Concurrent.Chan (writeChan)
import Control.Monad (unless, when)
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

data ImplicitReconnect = WithImplicitReconnect | NoImplicitReconnect
  deriving (Eq, Show)

sendPayload :: LocalNode 
            -> Identifier
            -> Identifier
            -> ImplicitReconnect
            -> [BSS.ByteString] 
            -> IO ()
sendPayload node from to implicitReconnect payload = do
  mConn <- connBetween node from to
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
    when (implicitReconnect == WithImplicitReconnect) $
      disconnect node from to 

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

disconnect :: LocalNode -> Identifier -> Identifier -> IO ()
disconnect node from to =
  modifyMVar_ (localState node) $ \st -> 
    case st ^. localConnectionBetween from to of
      Nothing -> 
        return st
      Just conn -> do
        NT.close conn 
        return (localConnectionBetween from to ^= Nothing $ st)
