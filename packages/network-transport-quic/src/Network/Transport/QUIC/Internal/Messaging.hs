{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Network.Transport.QUIC.Internal.Messaging (
    sendMessage,
    receiveMessage,

    -- * Specialized messages
    sendAck,
    recvAck,

    -- * Re-exported for testing
    encodeMessage,
    decodeMessage,
) where

import Control.Exception (catch, mask, throwIO)
import Control.Monad (unless)
import Data.Binary.Builder qualified as Builder
import Data.Bits (shiftL)
import Data.ByteString (StrictByteString, toStrict)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.Functor ((<&>))
import Data.Word (Word32, Word8)
import GHC.Exception (Exception)
import Network.QUIC (Stream)
import Network.QUIC qualified as QUIC
import Network.Transport.QUIC.Internal.QUICTransport (EndPointId)
import System.Timeout (timeout)

{- | Send a message to a remote endpoint ID

This function is thread-safe; while the data is sending, asynchronous
exceptions are masked, to be rethrown after the data is sent.
-}
sendMessage ::
    Stream ->
    EndPointId ->
    [StrictByteString] ->
    IO ()
sendMessage stream endpointId message = mask $ \restore ->
    restore (QUIC.sendStreamMany stream (encodeMessage endpointId message))
        `catch` (\(ex :: QUIC.QUICException) -> throwIO ex)

{- | Receive a message, including its local destination endpoint ID

This function is thread-safe; while the data is being received, asynchronous
exceptions are masked, to be rethrown after the data is sent.
-}
receiveMessage ::
    Stream ->
    IO (Either String (EndPointId, StrictByteString))
receiveMessage stream = mask $ \restore ->
    restore (decodeMessage (QUIC.recvStream stream))
        `catch` (\(ex :: QUIC.QUICException) -> throwIO ex)

{- | Encode a message.

The encoding is composed of a header, and the payload.
The message header is composed of two 32-bit numbers:
 The endpoint ID of the destination endpoint, padded to a 32-bit big endian number;
 The length of the payload, again padded to a 32-bit big endian number
-}
encodeMessage ::
    EndPointId ->
    [StrictByteString] ->
    [StrictByteString]
encodeMessage endpointId message
    | endpointId < 0 = error "Negative EndPointId"
    | otherwise =
        [header] <> message
  where
    -- The message header is composed of two 32-bit numbers:
    --  The endpoint ID of the destination endpoint;
    --  The length of the payload
    header =
        toStrict $
            Builder.toLazyByteString $
                Builder.word32BE (fromIntegral endpointId) <> Builder.word32BE (fromIntegral (sum (BS.length <$> message)))

decodeMessage :: (Int -> IO StrictByteString) -> IO (Either String (EndPointId, StrictByteString))
decodeMessage getBytes = do
    header <- getBytes 8
    if BS.null header
        then pure $ Left "end-of-stream"
        else case BS.unpack header of
            [e1, e2, e3, e4, l1, l2, l3, l4] ->
                let endpointId = fromIntegral $ w32BE e1 e2 e3 e4
                    messageLength = w32BE l1 l2 l3 l4
                 in getBytes (fromIntegral messageLength) <&> Right . (endpointId,)
            _ -> pure $ Left "Message header could not be decoded"

-- | Build a 32-bit number in big-endian encoding from bytes
w32BE :: Word8 -> Word8 -> Word8 -> Word8 -> Word32
w32BE w1 w2 w3 w4 =
    let nbitsInByte = 8
     in -- This is clunky AF
        sum
            [ fromIntegral w1 `shiftL` (3 * nbitsInByte)
            , fromIntegral w2 `shiftL` (2 * nbitsInByte)
            , fromIntegral w3 `shiftL` nbitsInByte
            , fromIntegral w4
            ]

newtype AckException = AckException String
    deriving (Show, Eq)

instance Exception AckException

ackMessage :: StrictByteString
ackMessage = toStrict (Builder.toLazyByteString (Builder.word32BE 0))

sendAck :: Stream -> IO ()
sendAck =
    flip
        QUIC.sendStream
        ackMessage

recvAck :: Stream -> IO ()
recvAck stream =
    -- TODO: make timeout configurable
    timeout 500_000 (QUIC.recvStream stream (BS.length ackMessage))
        >>= maybe
            (throwIO (AckException "Connection ack not received within acceptable timeframe"))
            (\ack -> unless (ack == ackMessage) (throwIO (AckException "Unexpected new connection ack")))