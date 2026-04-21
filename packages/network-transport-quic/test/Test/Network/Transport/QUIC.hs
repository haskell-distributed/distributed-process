{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Network.Transport.QUIC (tests) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (replicateM_)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Network.Transport (EndPoint (..), Event (ConnectionClosed), Reliability (..), Transport (..), close, defaultConnectHints, send)
import Network.Transport.QUIC (QUICTransportConfig (..))
import Network.Transport.QUIC qualified as QUIC
import Network.Transport.Tests (echoServer)
import Network.Transport.Tests qualified as Tests
import Network.Transport.Tests.Auxiliary (forkTry)
import Network.Transport.Tests.Expect (expectConnectionOpened, expectEq, expectReceived, expectRight)
import Network.Transport.Util (spawn)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.Flaky (flakyTest, limitRetries, constantDelay)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Network.Transport.QUIC"
    [ testCaseWithTimeout "ping-pong" $ withQUICTransport $ flip Tests.testPingPong 5,
      testCaseWithTimeout "endpoints" $ withQUICTransport $ flip Tests.testEndPoints 5,
      testCaseWithTimeout "connections" $ withQUICTransport $ flip Tests.testConnections 5,
      testCaseWithTimeout "closeOneConnection" $ withQUICTransport $ flip Tests.testCloseOneConnection 5,
      testCaseWithTimeout "closeOneDirection" $ withQUICTransport $ flip Tests.testCloseOneDirection 5,
      flaky $ testCaseWithTimeout "closeReopen" $ withQUICTransport $ flip Tests.testCloseReopen 5,
      -- This test is flaky specifically in Github Actions
      flaky $ testCaseWithTimeout "parallelConnects" $ withQUICTransport $ flip Tests.testParallelConnects 5,
      testCaseWithTimeout "selfSend" $ withQUICTransport Tests.testSelfSend,
      flaky $ testCaseWithTimeout "closeTwice" $ withQUICTransport $ flip Tests.testCloseTwice 1,
      testCaseWithTimeout "connectToSelf" $ withQUICTransport $ flip Tests.testConnectToSelf 5,
      testCaseWithTimeout "connectToSelfTwice" $ withQUICTransport $ flip Tests.testConnectToSelfTwice 5,
      testCaseWithTimeout "closeSelf" $ withQUICTransport (Tests.testCloseSelf . pure . Right),
      flaky $ testCaseWithTimeout "closeEndPoint" $ withQUICTransport $ flip Tests.testCloseEndPoint 1,
      flaky $ testCaseWithTimeout "closeTransport" $ Tests.testCloseTransport mkQUICTransport,
      flaky $ testCaseWithTimeout "connectClosedEndPoint" $ withQUICTransport Tests.testConnectClosedEndPoint,
      flaky testSendVeryLargeMessages
    ]

flaky :: TestTree -> TestTree
flaky = flakyTest (limitRetries 3 <> constantDelay 1_000)

-- | Ensure that a test does not run for too long
testCaseWithTimeout :: TestName -> Assertion -> TestTree
testCaseWithTimeout name assertion =
  testCase name $
    timeout 1_000_000 assertion
      >>= maybe (assertFailure "Test timed out") pure

mkQUICTransport :: IO (Either String Transport)
mkQUICTransport = do
  QUIC.credentialLoadX509
    -- Generate a self-signed x509v3 certificate using this nifty tool:
    -- https://certificatetools.com/
    ("test" </> "credentials" </> "cert.crt")
    ("test" </> "credentials" </> "cert.key")
    >>= \case
      Left errmsg -> pure $ Left errmsg
      Right creds ->
        Right
          <$> QUIC.createTransport
            ( QUICTransportConfig
                { hostName = "127.0.0.1",
                  serviceName = "0",
                  credentials = creds :| [],
                  -- credentials are self-signed
                  validateCredentials = False
                }
            )

withQUICTransport :: (Transport -> IO a) -> IO a
withQUICTransport =
  bracket
    (mkQUICTransport >>= either assertFailure pure)
    closeTransport

testSendVeryLargeMessages :: TestTree
testSendVeryLargeMessages = testCase "Send very large messages" $ withQUICTransport $ \transport -> do
  server <- spawn transport echoServer
  result <- newEmptyMVar

  let numPings = 10
  let bigMessage = BS.replicate 4091 66 -- Using an odd number of bytes (4091) to test message boundaries
  _ <- forkTry $ do
    endpoint <- expectRight "newEndPoint" =<< newEndPoint transport
    ping endpoint server numPings bigMessage
    putMVar result ()

  takeMVar result
  where
    ping endpoint serverAddr numPings message = do
      conn <- expectRight "connect" =<< connect endpoint serverAddr ReliableOrdered defaultConnectHints

      (cid, _, _) <- expectConnectionOpened =<< receive endpoint

      replicateM_ numPings $ do
        _ <- send conn [message]
        (cid', payload) <- expectReceived =<< receive endpoint
        expectEq "connection id" cid cid'
        expectEq "payload"       [message] payload

      close conn

      receive endpoint >>= (@?=) (ConnectionClosed cid)
