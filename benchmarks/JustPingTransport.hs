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
import Network.Transport (newConnection, receive, connect, send, defaultHints,
			  serialize, deserialize, SourceEnd, TargetEnd)
import Network.Transport.TCP (mkTransport, TCPConfig (..))

main :: IO ()
main = do
  [pingsStr]  <- getArgs
  serverAddr <- newEmptyMVar
  clientAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Start the server
  forkIO $ do
    -- establish transport
    putStrLn "server: creating TCP connection"
    transport <- mkTransport $ TCPConfig defaultHints "127.0.0.1" "8080"

    -- create ping end
    (sourceAddrPing, targetEndPing) <- newConnection transport
    putMVar serverAddr sourceAddrPing
   
    -- create pong end
    sourceAddrPong <- takeMVar clientAddr
    sourceEndPong <- connect sourceAddrPong

    -- reply to pings with pongs
    putStrLn "server: awaiting client connection"
    pong targetEndPing sourceEndPong 

  -- Start the client
  forkIO $ do
    sourceAddr <- takeMVar serverAddr
    let pings = read pingsStr

    -- establish transport
    transport <- mkTransport $ TCPConfig defaultHints "127.0.0.1" "8081"

    -- Create ping end
    sourceEndPing <- connect sourceAddr

    -- Create pong end
    (sourceAddrPong, targetEndPong) <- newConnection transport
    putMVar clientAddr sourceAddrPong

    ping sourceEndPing targetEndPong pings
    putMVar clientDone ()

  -- Wait for the client to finish
  takeMVar clientDone

pingMessage :: ByteString
pingMessage = pack "ping123"

ping :: SourceEnd -> TargetEnd -> Int -> IO () 
ping sourceEndPing targetEndPong pings = go pings
  where
    go :: Int -> IO ()
    go 0 = do 
      putStrLn $ "client did " ++ show pings ++ " pings"
    go !i = do
      before <- getCurrentTime
      send sourceEndPing [pingMessage]
      [bs] <- receive targetEndPong
      after <- getCurrentTime
      -- putStrLn $ "client received " ++ unpack bs
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      hPutStrLn stderr $ show i ++ " " ++ show latency 
      go (i - 1)

pong :: TargetEnd -> SourceEnd -> IO ()
pong targetEndPing sourceEndPong = do
  [bs] <- receive targetEndPing 
  -- putStrLn $ "server received " ++ unpack bs
  when (BS.length bs > 0) $ do
    send sourceEndPong [bs]
    pong targetEndPing sourceEndPong 
