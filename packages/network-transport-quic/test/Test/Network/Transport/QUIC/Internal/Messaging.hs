{-# LANGUAGE OverloadedStrings #-}

module Test.Network.Transport.QUIC.Internal.Messaging (tests) where

import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.ByteString (ByteString)
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
    -- The connection ID and message length are encoded and decoded the same way, to/from
    -- a Word32.
    -- To exercise the parsing of Word32s, we need to make sure that the range
    -- of data is generated above a Word8 (255), including the connection ID
    -- and the number of bytes in the message
    endpointId <- fmap fromIntegral <$> forAll $ Gen.word32 Range.constantBounded

    messages <- forAll (Gen.list (Range.linear 0 3) (Gen.bytes (Range.linear 1 4096)))
    let encoded = mconcat $ encodeMessage endpointId messages

    getBytes <- liftIO $ messageDecoder encoded

    decoded <- liftIO $ decodeMessage getBytes
    Right (Message endpointId messages) === decoded

messageDecoder :: ByteString -> IO (Int -> IO ByteString)
messageDecoder allBytes = do
    ref <- newIORef allBytes
    pure
        ( \nbytes -> do
            atomicModifyIORef
                ref
                ( \remainingBytes ->
                    ( BS.drop nbytes remainingBytes
                    , BS.take nbytes remainingBytes
                    )
                )
        )
