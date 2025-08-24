{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Test.Network.Transport.QUIC (tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, threadDelay)
import Control.Concurrent.MVar (readMVar)
import Control.Exception (bracket)
import Control.Monad (void)
import Data.List.NonEmpty qualified as NonEmpty
import Network.Transport (Event (Received), Transport (closeTransport, newEndPoint), address, connect)
import Network.Transport qualified as NT
import Network.Transport.QUIC qualified as QUIC
import Network.Transport.Tests qualified as Tests
import Network.Transport.Util (spawn)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
    testGroup
        "Network.Transport.QUIC"
        [ testCaseWithTimeout "trivial" trivialTest
        , testCaseWithTimeout "ping-pong" $ withQUICTransport $ flip Tests.testPingPong 5
        ]

-- | Ensure that a test does not run for too long
testCaseWithTimeout :: TestName -> Assertion -> TestTree
testCaseWithTimeout name assertion =
    testCase name $
        timeout 10_000_000 assertion
            >>= maybe (assertFailure "Test timed out") pure

trivialTest :: Assertion
trivialTest = withQUICTransport $ \transport -> do
    Right endpoint1 <- newEndPoint transport
    Right endpoint2 <- newEndPoint transport

    void $
        forkIO $ do
            Right conn1 <- connect endpoint1 (address endpoint2) undefined undefined
            -- Right conn2 <- connect endpoint2 (address endpoint1) undefined undefined

            NT.send conn1 ["hello world"] >>= either (assertFailure . show) pure
    -- _ <- forkIO $ NT.send conn2 ["hello world"] >>= either (assertFailure . show) pure

    result <- newEmptyMVar
    void $
        forkIO $ do
            NT.receive endpoint2 >>= putMVar result

    readMVar result >>= \case
        Received _ bytes  -> assertEqual mempty ["hello world"] bytes
        other -> assertFailure $ "Unexpected event " <> show other

-- event2 <- NT.receive endpoint2

-- print event2

withQUICTransport :: (Transport -> IO a) -> IO a
withQUICTransport =
    bracket
        ( QUIC.credentialLoadX509
            -- Generate a self-signed x509v3 certificate using this nifty tool:
            -- https://certificatetools.com/
            ("test" </> "credentials" </> "cert.crt")
            ("test" </> "credentials" </> "cert.key")
            >>= either assertFailure pure
            >>= QUIC.createTransport
                "127.0.0.1"
                "42065"
                . NonEmpty.singleton
        )
        closeTransport
