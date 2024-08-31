{-# LANGUAGE CPP, BangPatterns #-}

module Main where

import Control.Monad

import Data.Int
import System.Environment (getArgs, withArgs)
import Data.Time (getCurrentTime, diffUTCTime, NominalDiffTime)
import System.IO (withFile, IOMode(..), hPutStrLn, Handle, stderr)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import qualified Network.Socket as N
import Debug.Trace
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack, unpack)
import qualified Data.ByteString as BS
import qualified Network.Socket.ByteString as NBS
import Data.Time (getCurrentTime, diffUTCTime, NominalDiffTime)
import Network.Transport
import Network.Transport.TCP

main :: IO ()
main = do
  [pingsStr]  <- getArgs
  serverAddr <- newEmptyMVar
  clientAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Start the server
  forkIO $ do
    -- establish transport and endpoint
    putStrLn "server: creating TCP connection"
    Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
    Right endpoint  <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    -- Connect to the client so that we can reply
    theirAddr <- takeMVar clientAddr
    Right conn <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

    -- reply to pings with pongs
    putStrLn "server: awaiting client connection"
    ConnectionOpened _ _ _ <- receive endpoint
    pong endpoint conn

  -- Start the client
  forkIO $ do
    let pings = read pingsStr

    -- establish transport and endpoint
    Right transport <- createTransport "127.0.0.1" "8081" defaultTCPParameters
    Right endpoint  <- newEndPoint transport
    putMVar clientAddr (address endpoint)

    -- Connect to the server to send pings
    theirAddr <- takeMVar serverAddr
    Right conn <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

    -- Send pings, waiting for a reply after every ping
    ConnectionOpened _ _ _ <- receive endpoint
    ping endpoint conn pings
    putMVar clientDone ()

  -- Wait for the client to finish
  takeMVar clientDone

pingMessage :: [ByteString]
pingMessage = [pack "ping123"]

ping :: EndPoint -> Connection -> Int -> IO ()
ping endpoint conn pings = go pings
  where
    go :: Int -> IO ()
    go 0 = do
      putStrLn $ "client did " ++ show pings ++ " pings"
    go !i = do
      before <- getCurrentTime
      send conn pingMessage
      Received _ _payload <- receive endpoint
      after <- getCurrentTime
      -- putStrLn $ "client received " ++ show _payload
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      hPutStrLn stderr $ show i ++ " " ++ show latency
      go (i - 1)

pong :: EndPoint -> Connection -> IO ()
pong endpoint conn = go
  where
    go = do
      msg <- receive endpoint
      case msg of
        Received _ payload -> send conn payload >> go
        ConnectionClosed _ -> return ()
        _ -> fail "Unexpected message"
