{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Network.Transport.QUIC.Internal.Messaging
  ( -- * Connections
    ServerConnId,
    serverSelfConnId,
    firstNonReservedServerConnId,
    ClientConnId,
    createConnectionId,
    sendMessage,
    receiveMessage,
    messageReceiver,
    MessageReceived (..),

    -- * Specialized messages
    sendAck,
    sendRejection,
    recvAck,
    recvWord32,
    sendCloseConnection,
    sendCloseEndPoint,
    closeTimeout,

    -- * Handshake protocol
    handshake,

    -- * Re-exported for testing
    encodeMessage,
    decodeMessage,
  )
where

import Control.Exception (SomeAsyncException, SomeException, catch, displayException, fromException, mask, throwIO, try)
import Control.Monad (replicateM)
import Data.Binary (Binary)
import Data.Binary qualified as Binary
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Functor ((<&>))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word32, Word8)
import GHC.Exception (Exception)
import Network.QUIC (Stream)
import Network.QUIC qualified as QUIC
import Network.Transport (ConnectionId, EndPointAddress)
import Network.Transport.Internal (decodeWord32, encodeWord32)
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (QUICAddr), decodeQUICAddr)
import System.Timeout (timeout)

-- | Send a message on the stream.
--
-- This function is thread-safe; while the data is sending, asynchronous
-- exceptions are masked, to be rethrown after the data is sent.
sendMessage ::
  Stream ->
  [ByteString] ->
  IO (Either QUIC.QUICException ())
sendMessage stream messages =
  try
    ( QUIC.sendStreamMany
        stream
        (encodeMessage messages)
    )

-- | Receive a single message.
--
-- To receive several messages from a stream, use 'messageReceiver'.
receiveMessage ::
  Stream ->
  IO (Either String MessageReceived)
receiveMessage stream = messageReceiver stream >>= id

-- | Create an action which receives the next message from a stream, every time it
-- is run. Only one such receiver should exist per stream.
messageReceiver ::
  Stream ->
  IO (IO (Either String MessageReceived))
messageReceiver stream = do
  -- The whole purpose of 'messageReceiver' is to amortize
  -- reading with the following buffer
  buffer <- newIORef BS.empty
  pure $
    decodeMessage
      -- Note that 'recvStream' may return less bytes than requested.
      -- Therefore, we must wrap it in 'getAllBytes'.
      (getAllBytes buffer (QUIC.recvStream stream))
      `catch` (\(ex :: QUIC.QUICException) -> throwIO ex)

-- | Encode a message.
--
-- The encoding is composed of a header, and the payloads.
-- The message header is composed of:
-- 1. A control byte, to determine how the message should be parsed.
-- 2. A 32-bit word that encodes the number of frames in the message
--
-- The payload frames are each prepended with the length of the frame.
encodeMessage ::
  [ByteString] ->
  [ByteString]
encodeMessage messages =
  BS.concat
    [ BS.singleton messageControlByte,
      encodeWord32 (fromIntegral $ length messages)
    ]
    : [encodeWord32 (fromIntegral $ BS.length message) <> message | message <- messages]

decodeMessage ::
  (Int -> IO ByteString) ->
  IO (Either String MessageReceived)
decodeMessage get =
  get 1
    >>= maybe
      (pure $ Right StreamClosed)
      ( \controlByte ->
          go controlByte `catch` \(ex :: SomeException) ->
            case fromException ex of
              Just (_ :: SomeAsyncException) -> throwIO ex
              Nothing -> pure $ Left (displayException ex)
      )
      . flip BS.indexMaybe 0
  where
    go ctrl
      | ctrl == closeEndPointControlByte = pure $ Right CloseEndPoint
      | ctrl == closeConnectionControlByte = pure $ Right CloseConnection
      | ctrl == messageControlByte = do
          numMessages <- getWord32
          messages <- replicateM (fromIntegral numMessages) $ do
            getWord32 >>= get . fromIntegral
          pure . Right $ Message messages
      | otherwise = pure $ Left $ "Unsupported control byte: " <> show ctrl
    getWord32 = get 4 <&> decodeWord32

-- | Wrap a method to fetch bytes, to ensure that we always get exactly the
-- intended number of bytes. Returns early (with the accumulated bytes) if the
-- underlying fetcher signals EOF by returning an empty ByteString; otherwise a
-- fetcher that repeatedly returns empty after a peer FIN would cause this to
-- spin forever.
getAllBytes ::
  -- | Bytes fetched, but not yet consumed
  IORef ByteString ->
  -- | Function to fetch at most 'n' bytes
  (Int -> IO ByteString) ->
  -- | Function to fetch exactly 'n' bytes (or fewer on EOF)
  (Int -> IO ByteString)
getAllBytes buffer get n = do
  buffered <- readIORef buffer
  go [buffered] (BS.length buffered)
  where
    go !acc !have
      | have >= n = do
          let (wanted, rest) = BS.splitAt n (BS.concat (reverse acc))
          writeIORef buffer rest
          pure wanted
      | otherwise =
          get (max (n - have) fetchSize) >>= \bytes ->
            if BS.null bytes
              then do
                writeIORef buffer BS.empty
                pure $ BS.concat (reverse acc)
              else go (bytes : acc) (have + BS.length bytes)

    fetchSize :: Int
    fetchSize = 16384

data MessageReceived
  = Message {-# UNPACK #-} ![ByteString]
  | CloseConnection
  | CloseEndPoint
  | StreamClosed
  deriving (Show, Eq)

newtype AckException = AckException String
  deriving (Show, Eq)

instance Exception AckException

ackMessage :: ByteString
ackMessage = BS.singleton connectionAcceptedControlByte

rejectMessage :: ByteString
rejectMessage = BS.singleton connectionRejectedControlByte

sendAck :: Stream -> IO ()
sendAck =
  flip
    QUIC.sendStream
    ackMessage

sendRejection :: Stream -> IO ()
sendRejection =
  flip
    QUIC.sendStream
    rejectMessage

recvAck :: Stream -> IO (Either () ())
recvAck stream = do
  QUIC.recvStream stream 1 >>= go
  where
    go response
      | response == ackMessage = pure $ Right ()
      | response == rejectMessage = pure $ Left ()
      | otherwise = throwIO (AckException "Unexpected ack response")

-- | Receive a 'Word32'
--
-- This function is thread-safe; while the data is being received, asynchronous
-- exceptions are masked, to be rethrown after the data is received.
recvWord32 ::
  Stream ->
  IO (Either String Word32)
recvWord32 stream =
  mask $ \restore ->
    restore
      (QUIC.recvStream stream 4 <&> Right . decodeWord32)
      `catch` (\(ex :: SomeException) -> pure $ Left (displayException ex))

-- | We perform some special actions based on a message's control byte.
-- For example, if a client wants to close a connection.
type ControlByte = Word8

connectionAcceptedControlByte :: ControlByte
connectionAcceptedControlByte = 0

connectionRejectedControlByte :: ControlByte
connectionRejectedControlByte = 1

messageControlByte :: ControlByte
messageControlByte = 2

closeEndPointControlByte :: ControlByte
closeEndPointControlByte = 127

closeConnectionControlByte :: ControlByte
closeConnectionControlByte = 255

-- | How long to wait for the remote end to take a message which closes a connection,
-- or to acknowledge that a stream was closed.
closeTimeout :: Int
closeTimeout = 1_000_000

-- | Send a control message which says that we are done with a stream.
--
-- Closing must never wait on the remote end: if it stopped reading, or is gone
-- without us having noticed, the stream's flow control window may never reopen and
-- sending would block forever. We give up after 'closeTimeout' instead; whoever is
-- on the other side will find out when the QUIC connection ends.
sendClosing :: ControlByte -> Stream -> IO (Either QUIC.QUICException ())
sendClosing controlByte stream =
  try (timeout closeTimeout (QUIC.sendStream stream (BS.singleton controlByte)))
    <&> fmap (const ())

-- | Send a message to close the connection.
sendCloseConnection :: Stream -> IO (Either QUIC.QUICException ())
sendCloseConnection = sendClosing closeConnectionControlByte

-- | Send a message to close the endpoint.
sendCloseEndPoint :: Stream -> IO (Either QUIC.QUICException ())
sendCloseEndPoint = sendClosing closeEndPointControlByte

-- | Handshake protocol that a client, connecting to a remote endpoint,
-- has to perform:
--
-- 1. client -> server: address payload
-- 2. server -> client: ack1 (handshake payload accepted)
-- 3. server -> client: ack2 (ConnectionOpened has been enqueued on server's endpoint)
--
-- The ack2 step is load-bearing: when this function returns, the server has
-- already written ConnectionOpened to its local queue. Without it, the server's
-- @connect@ would return before the peer's queue has the ConnectionOpened event,
-- which races with subsequent sends on other connections.
handshake ::
  (EndPointAddress, EndPointAddress) ->
  Stream ->
  IO (Either () ())
handshake (ourAddress, theirAddress) stream =
  case decodeQUICAddr theirAddress of
    Left errmsg -> throwIO $ userError ("Could not decode QUIC address: " <> errmsg)
    Right (QUICAddr _ _ serverEndPointId) -> do
      let encodedPayload = BS.toStrict $ Binary.encode (ourAddress, serverEndPointId)
          payloadLength = encodeWord32 $ fromIntegral (BS.length encodedPayload)

      try
        ( QUIC.sendStream
            stream
            (BS.concat [payloadLength, encodedPayload])
        )
        >>= \case
          Left (_exc :: SomeException) -> pure $ Left ()
          Right _ ->
            recvAck stream >>= \case
              Left () -> pure $ Left ()
              Right () -> recvAck stream

-- | Part of the connection ID that is client-allocated.
newtype ClientConnId = ClientConnId Word32
  deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num, Binary)

-- | Part of the connection ID that is server-allocated.
newtype ServerConnId = ServerConnId Word32
  deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num)

-- | Self-connection
serverSelfConnId :: ServerConnId
serverSelfConnId = 0

-- | We reserve some connection IDs for special heavyweight connections
firstNonReservedServerConnId :: ServerConnId
firstNonReservedServerConnId = 1

-- | Construct a ConnectionId
createConnectionId ::
  ServerConnId ->
  ClientConnId ->
  ConnectionId
createConnectionId sid cid =
  (fromIntegral sid `shiftL` 32) .|. fromIntegral cid
