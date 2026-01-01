{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (forConcurrently_)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally, throwIO)
import Control.Monad (forM_, replicateM, void, when)
import qualified Data.ByteString as BS
import Data.IORef (
  atomicModifyIORef',
  newIORef,
 )
import Data.List.NonEmpty (NonEmpty (..))
import Network.Transport (
  Connection (send),
  EndPoint (address, connect, receive),
  Event (ConnectionOpened, Received),
  Reliability (ReliableOrdered),
  Transport (closeTransport, newEndPoint),
  defaultConnectHints,
 )
import qualified Network.Transport.QUIC as QUIC
import qualified Network.Transport.TCP as TCP
import System.FilePath ((</>))
import Test.Tasty (TestTree)
import Test.Tasty.Bench (bench, bgroup, defaultMain, nfIO)

data TransportConfig = TransportConfig
  { transportName :: String
  , mkTransport :: IO Transport
  }

tcpConfig :: TransportConfig
tcpConfig =
  TransportConfig
    { transportName = "TCP"
    , mkTransport = do
        Right t <- TCP.createTransport (TCP.defaultTCPAddr "127.0.0.1" "0") TCP.defaultTCPParameters
        pure t
    }

quicConfig :: TransportConfig
quicConfig =
  TransportConfig
    { transportName = "QUIC"
    , mkTransport =
        QUIC.credentialLoadX509
          -- Generate a self-signed x509v3 certificate using this nifty tool:
          -- https://certificatetools.com/
          ("test" </> "credentials" </> "cert.crt")
          ("test" </> "credentials" </> "cert.key")
          >>= \case
            Left errmsg -> throwIO $ userError errmsg
            Right credentials ->
              QUIC.createTransport "127.0.0.1" "0" (credentials :| [])
    }

data BenchParams = BenchParams
  { messageSize :: !Int
  , messageCount :: !Int
  , connectionCount :: !Int
  }

smallMessages, mediumMessages, largeMessages :: BenchParams
smallMessages = BenchParams{messageSize = 64, messageCount = 10_000, connectionCount = 1}
mediumMessages = BenchParams{messageSize = 1024, messageCount = 1_000, connectionCount = 1}
largeMessages = BenchParams{messageSize = 4096, messageCount = 100, connectionCount = 1}

multiConn :: Int -> BenchParams -> BenchParams
multiConn n p = p{connectionCount = n}

throughputBench :: TransportConfig -> BenchParams -> IO ()
throughputBench TransportConfig{mkTransport} BenchParams{messageSize, messageCount, connectionCount} = do
  transport <- mkTransport
  flip finally (closeTransport transport) $ do
    Right senderEP <- newEndPoint transport
    Right receiverEP <- newEndPoint transport

    let payload = BS.replicate messageSize 0x42
        totalMessages = messageCount * connectionCount

    receiverReady <- newEmptyMVar
    receiverDone <- newEmptyMVar

    void $ forkIO $ do
      connsEstablished <- newIORef (0 :: Int)
      let waitForConnections = do
            event <- receive receiverEP
            case event of
              ConnectionOpened{} -> do
                n <- atomicModifyIORef' connsEstablished (\x -> (x + 1, x + 1))
                when (n < connectionCount) waitForConnections
              _ -> waitForConnections
      waitForConnections
      putMVar receiverReady ()

      msgsReceived <- newIORef (0 :: Int)
      let recvLoop = do
            event <- receive receiverEP
            case event of
              Received _ _ -> do
                n <- atomicModifyIORef' msgsReceived (\x -> (x + 1, x + 1))
                when (n < totalMessages) recvLoop
              _ -> recvLoop
      recvLoop
      putMVar receiverDone ()

    let receiverAddr = address receiverEP
    connections <-
      replicateM
        connectionCount
        ( connect senderEP receiverAddr ReliableOrdered defaultConnectHints >>= either throwIO pure
        )

    takeMVar receiverReady

    forConcurrently_ connections $ \conn ->
      forM_ [0 .. messageCount] $ \_ -> send conn [payload]

    takeMVar receiverDone

benchTransport :: TransportConfig -> TestTree
benchTransport cfg@TransportConfig{transportName} =
  bgroup
    transportName
    [ bgroup
        "throughput"
        [ bgroup
            "single-connection"
            [ bench "small-msg" $ nfIO $ throughputBench cfg smallMessages
            , bench "default-msg" $ nfIO $ throughputBench cfg mediumMessages
            , bench "large-msg" $ nfIO $ throughputBench cfg largeMessages
            ]
        , bgroup
            "multi-connection"
            [ bench "2-conn" $ nfIO $ throughputBench cfg smallMessages{connectionCount = 2, messageCount = 10_000}
            , bench "5-conn" $ nfIO $ throughputBench cfg smallMessages{connectionCount = 5, messageCount = 10_000}
            , bench "10-conn" $ nfIO $ throughputBench cfg smallMessages{connectionCount = 10, messageCount = 5_000}
            ]
        ]
    ]

main :: IO ()
main =
  defaultMain
    [ benchTransport tcpConfig
    , benchTransport quicConfig
    ]
