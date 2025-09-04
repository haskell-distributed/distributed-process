{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.Network.Transport.QUIC (tests) where

import Control.Exception (bracket)
import Data.List.NonEmpty qualified as NonEmpty
import Network.Transport (Transport (closeTransport))
import Network.Transport.QUIC qualified as QUIC
import Network.Transport.Tests qualified as Tests
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
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
        , -- testCloseReopen is specific to the TCP transport, and we therefore do not run this test
          testCaseWithTimeout "parallelConnects" $ withQUICTransport $ flip Tests.testParallelConnects 5
        ]

-- | Ensure that a test does not run for too long
testCaseWithTimeout :: TestName -> Assertion -> TestTree
testCaseWithTimeout name assertion =
    testCase name $
        timeout 10_000_000 assertion
            >>= maybe (assertFailure "Test timed out") pure


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
