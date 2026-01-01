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
import Network.Transport (EndPoint (..), Event (ConnectionClosed, ConnectionOpened, Received), Reliability (..), Transport (..), close, defaultConnectHints, send)
import Network.Transport.QUIC (QUICTransportConfig (..))
import Network.Transport.QUIC qualified as QUIC
import Network.Transport.Tests (echoServer)
import Network.Transport.Tests qualified as Tests
import Network.Transport.Tests.Auxiliary (forkTry)
import Network.Transport.Util (spawn)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.Flaky (flakyTest, limitRetries)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

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
flaky = flakyTest (limitRetries 3)

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
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings bigMessage
    putMVar result ()

  takeMVar result
  where
    ping endpoint serverAddr numPings message = do
      Right conn <- connect endpoint serverAddr ReliableOrdered defaultConnectHints

      ConnectionOpened cid _ _ <- receive endpoint

      replicateM_ numPings $ do
        _ <- send conn [message]
        Received cid' [reply] <- receive endpoint
        assertBool mempty $ cid == cid' && reply == message

      close conn

      receive endpoint >>= (@?=) (ConnectionClosed cid)
