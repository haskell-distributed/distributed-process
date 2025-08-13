{-# LANGUAGE LambdaCase #-}

module Test.Network.Transport.QUIC.Internal.Messaging (tests) where

import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.ByteString (StrictByteString)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef, newIORef)
import Hedgehog (forAll, property, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Network.Transport.QUIC.Internal (MessageReceived (..), decodeMessage, encodeMessage)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Hedgehog (testProperty)

tests :: TestTree
tests =
    testGroup
        "Messaging"
        [testMessageEncodingAndDecoding]

testMessageEncodingAndDecoding :: TestTree
testMessageEncodingAndDecoding = testProperty "Encoded messages can be decoded" $ property $ do
    -- The endpoint ID and message length are encoded and decoded the same way, to/from
    -- a Word32.
    -- Since we don't want to generate insanely long messages in this test, we exercise the
    -- encoding/decoding of the endpoint ID by generating insanely large endpoint IDs
    endpointId <- fmap fromIntegral <$> forAll $ Gen.word32 Range.constantBounded

    message <- forAll (Gen.list (Range.linear 0 3) (Gen.bytes (Range.linear 0 2048)))
    let encoded = mconcat $ encodeMessage endpointId message

    getBytes <- liftIO $ messageDecoder encoded

    liftIO (decodeMessage getBytes) >>= \case
        Left errmsg -> fail errmsg
        Right StreamClosed -> fail "stream closed"
        Right (Message eid bytes) -> (endpointId, mconcat message) === (eid, bytes)

messageDecoder :: StrictByteString -> IO (Int -> IO StrictByteString)
messageDecoder allBytes = do
    ref <- newIORef allBytes
    pure
        ( \nbytes -> do
            atomicModifyIORef
                ref
                ( \remainingBytes ->
                    (BS.drop nbytes remainingBytes, BS.take nbytes remainingBytes)
                )
        )