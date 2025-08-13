{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Network.Transport.QUIC (tests) where

import Control.Exception (Exception (displayException), SomeException, bracket, try)
import Data.List.NonEmpty qualified as NonEmpty
import Network.Transport (Transport (..))
import Network.Transport.QUIC qualified as QUIC
import Network.Transport.Tests qualified as Tests
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.Flaky (flakyTest, limitRetries)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

tests :: TestTree
tests =
    testGroup
        "Network.Transport.QUIC"
        [ testCaseWithTimeout "ping-pong" $ withQUICTransport $ flip Tests.testPingPong 5
        , testCaseWithTimeout "endpoints" $ withQUICTransport $ flip Tests.testEndPoints 5
        , testCaseWithTimeout "connections" $ withQUICTransport $ flip Tests.testConnections 5
        , testCaseWithTimeout "closeOneConnection" $ withQUICTransport $ flip Tests.testCloseOneConnection 5
        , testCaseWithTimeout "closeOneDirection" $ withQUICTransport $ flip Tests.testCloseOneDirection 5
        , flaky $ testCaseWithTimeout "closeReopen" $ withQUICTransport $ flip Tests.testCloseReopen 5
        , testCaseWithTimeout "parallelConnects" $ withQUICTransport $ flip Tests.testParallelConnects 5
        , testCaseWithTimeout "selfSend" $ withQUICTransport Tests.testSelfSend
        , testCaseWithTimeout "sendAfterClose" $ withQUICTransport $ flip Tests.testSendAfterClose 5
        , flaky $ testCaseWithTimeout "closeTwice" $ withQUICTransport $ flip Tests.testCloseTwice 1 -- This is a little flaky
        , testCaseWithTimeout "connectToSelf" $ withQUICTransport $ flip Tests.testConnectToSelf 5
        , testCaseWithTimeout "connectToSelfTwice" $ withQUICTransport $ flip Tests.testConnectToSelfTwice 5
        , testCaseWithTimeout "closeSelf" $ withQUICTransport (Tests.testCloseSelf . pure . Right)
        , flaky $ testCaseWithTimeout "closeEndPoint" $ withQUICTransport $ flip Tests.testCloseEndPoint 1
        , flaky $ testCaseWithTimeout "closeTransport" $ Tests.testCloseTransport mkQUICTransport
        , flaky $ testCaseWithTimeout "connectClosedEndPoint" $ withQUICTransport Tests.testConnectClosedEndPoint
        ]

flaky :: TestTree -> TestTree
flaky = flakyTest (limitRetries 1)

-- | Ensure that a test does not run for too long
testCaseWithTimeout :: TestName -> Assertion -> TestTree
testCaseWithTimeout name assertion =
    testCase name $
        -- We need to use 'try' because the underlying tests
        -- are just IO actions that throw exceptions on failure.
        -- We must catch these exceptions to properly retry
        -- failed tests.
        timeout 1_000_000 (try assertion)
            >>= maybe (assertFailure "Test timed out") pure
            >>= either (\(exc :: SomeException) -> assertFailure (displayException exc)) pure

mkQUICTransport :: IO (Either String Transport)
mkQUICTransport = do
    QUIC.credentialLoadX509
        -- Generate a self-signed x509v3 certificate using this nifty tool:
        -- https://certificatetools.com/
        ("test" </> "credentials" </> "cert.crt")
        ("test" </> "credentials" </> "cert.key")
        >>= \case
            Left errmsg -> pure $ Left errmsg
            Right credentials ->
                Right
                    <$> QUIC.createTransport "127.0.0.1" "0" (NonEmpty.singleton credentials)

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
                "0"
                . NonEmpty.singleton
        )
        closeTransport
