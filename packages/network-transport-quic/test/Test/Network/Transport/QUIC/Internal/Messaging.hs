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
    -- The message length is encoded and decoded as a Word32. Generate data above
    -- a Word8 (255) to exercise the Word32 parsing of the number of bytes in each
    -- message.
    messages <- forAll (Gen.list (Range.linear 0 3) (Gen.bytes (Range.linear 1 4096)))
    let encoded = mconcat $ encodeMessage messages

    getBytes <- liftIO $ messageDecoder encoded

    decoded <- liftIO $ decodeMessage getBytes
    Right (Message messages) === decoded

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
