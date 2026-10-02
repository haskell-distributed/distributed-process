{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Network.Transport.QUIC (tests) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, replicateM, replicateM_)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Network.QUIC qualified as Q
import Network.QUIC.Client qualified as Q.Client
import Network.Transport (EndPoint (..), EndPointAddress (..), Event (..), EventErrorCode (..), Reliability (..), Transport (..), TransportError (..), close, defaultConnectHints, send)
import Network.Transport.QUIC (QUICTransportConfig (..))
import Network.Transport.QUIC qualified as QUIC
import Network.Transport.QUIC.Internal (QUICAddr (..), decodeQUICAddr, handshake)
import Network.Transport.Tests (echoServer)
import Network.Transport.Tests qualified as Tests
import Network.Transport.Tests.Auxiliary (forkTry)
import Network.Transport.Tests.Expect (expectConnectionClosed, expectConnectionOpened, expectEq, expectReceived, expectRight)
import Network.Transport.Util (spawn)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestName, TestTree, testGroup)
import Test.Tasty.Flaky (constantDelay, flakyTest, limitRetries)
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
      testCaseWithTimeout "closeReopen" $ withQUICTransport $ flip Tests.testCloseReopen 5,
      -- This test is flaky specifically in Github Actions
      flaky $ testCaseWithTimeout "parallelConnects" $ withQUICTransport $ flip Tests.testParallelConnects 5,
      testCaseWithTimeout "selfSend" $ withQUICTransport Tests.testSelfSend,
      testCaseWithTimeout "closeTwice" $ withQUICTransport $ flip Tests.testCloseTwice 1,
      testCaseWithTimeout "connectToSelf" $ withQUICTransport $ flip Tests.testConnectToSelf 5,
      testCaseWithTimeout "connectToSelfTwice" $ withQUICTransport $ flip Tests.testConnectToSelfTwice 5,
      testCaseWithTimeout "closeSelf" $ withQUICTransport (Tests.testCloseSelf . pure . Right),
      testCaseWithTimeout "closeEndPoint" $ withQUICTransport $ flip Tests.testCloseEndPoint 1,
      flaky $ testCaseWithTimeout "closeTransport" $ Tests.testCloseTransport mkQUICTransport,
      testCaseWithTimeout "connectClosedEndPoint" $ withQUICTransport Tests.testConnectClosedEndPoint,
      testCase "Send very large messages" $ withQUICTransport testSendVeryLargeMessages,
      testCaseWithTimeout "many concurrent connections to one endpoint" $ withQUICTransport testManyConnections,
      testCaseWithTimeout "a connection is closed before the next is opened" $ withQUICTransport testCloseThenConnect,
      testCaseWithTimeout "losing the remote end of an incoming connection is reported" $ withQUICTransport testIncomingConnectionLost
    ]

flaky :: TestTree -> TestTree
flaky = flakyTest (limitRetries 3 <> constantDelay 1_000)

-- | Ensure that a test does not run for too long
testCaseWithTimeout :: TestName -> Assertion -> TestTree
testCaseWithTimeout = testCaseWithTimeoutOf 1_000_000

-- | Like 'testCaseWithTimeout', with a timeout in microseconds.
testCaseWithTimeoutOf :: Int -> TestName -> Assertion -> TestTree
testCaseWithTimeoutOf microseconds name assertion =
  testCase name $
    timeout microseconds assertion
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
            ( ( QUIC.defaultQUICTransportConfig
                  "127.0.0.1"
                  (creds :| [])
              )
                { serviceName = "0",
                  validateCredentials = False
                }
            )

withQUICTransport :: (Transport -> IO a) -> IO a
withQUICTransport =
  bracket
    (mkQUICTransport >>= either assertFailure pure)
    closeTransport

testSendVeryLargeMessages :: Transport -> IO ()
testSendVeryLargeMessages transport = do
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
        expectEq "payload" [message] payload

      close conn

      receive endpoint >>= (@?=) (ConnectionClosed cid)

testManyConnections :: Transport -> IO ()
testManyConnections transport = do
  let numConnections = 200

  sender <- expectRight "newEndPoint (sender)" =<< newEndPoint transport
  receiver <- expectRight "newEndPoint (receiver)" =<< newEndPoint transport

  connected <- forM [1 .. numConnections :: Int] $ \i -> do
    result <- newEmptyMVar
    _ <- forkTry $ do
      conn <- expectRight "connect" =<< connect sender (address receiver) ReliableOrdered defaultConnectHints
      expectRight "send" =<< send conn [BSC.pack (show i)]
      putMVar result conn
    pure result
  conns <- mapM takeMVar connected

  events <- replicateM (2 * numConnections) (receive receiver)

  -- Every connection is opened before anything is received on it
  let ordered _ [] = True
      ordered opened (ConnectionOpened cid _ _ : rest) = ordered (cid : opened) rest
      ordered opened (Received cid _ : rest) = cid `elem` opened && ordered opened rest
      ordered opened (_ : rest) = ordered opened rest
  expectEq "events are ordered" True (ordered [] events)

  expectEq "payloads" (sort [BSC.pack (show i) | i <- [1 .. numConnections]]) (sort [p | Received _ [p] <- events])

  forM_ conns close
  closed <- replicateM numConnections (receive receiver)
  expectEq "all connections are closed" numConnections (length [() | ConnectionClosed _ <- closed])

testCloseThenConnect :: Transport -> IO ()
testCloseThenConnect transport = do
  sender <- expectRight "newEndPoint (sender)" =<< newEndPoint transport
  receiver <- expectRight "newEndPoint (receiver)" =<< newEndPoint transport

  replicateM_ 100 $ do
    a <- expectRight "connect (a)" =<< connect sender (address receiver) ReliableOrdered defaultConnectHints
    close a
    b <- expectRight "connect (b)" =<< connect sender (address receiver) ReliableOrdered defaultConnectHints
    close b

    (cidA, _, _) <- expectConnectionOpened =<< receive receiver
    closedA <- expectConnectionClosed =<< receive receiver
    expectEq "a is closed first" cidA closedA
    (cidB, _, _) <- expectConnectionOpened =<< receive receiver
    closedB <- expectConnectionClosed =<< receive receiver
    expectEq "then b is closed" cidB closedB

testIncomingConnectionLost :: Transport -> IO ()
testIncomingConnectionLost transport = do
  receiver <- expectRight "newEndPoint" =<< newEndPoint transport
  QUICAddr host port _ <- either assertFailure pure (decodeQUICAddr (address receiver))

  let clientAddress = EndPointAddress "client"
      clientConfig = Q.Client.defaultClientConfig {Q.Client.ccServerName = host, Q.Client.ccPortName = port, Q.Client.ccValidate = False}

  Q.Client.run clientConfig $ \conn -> do
    Q.waitEstablished conn
    stream <- Q.stream conn
    handshake (clientAddress, address receiver) stream >>= either (const $ assertFailure "handshake failed") pure

  (_, _, from) <- expectConnectionOpened =<< receive receiver
  expectEq "connection is from the client" clientAddress from

  receive receiver >>= \case
    ErrorEvent (TransportError (EventConnectionLost lost) _) -> expectEq "the lost connection is the client's" clientAddress lost
    other -> assertFailure $ "Expected the connection to be reported lost, but got " <> show other
