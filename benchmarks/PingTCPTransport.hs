{-# LANGUAGE CPP, BangPatterns #-}

module Main where

import Network.Transport (newConnection, receive, connect, send, defaultHints,
			  serialize, deserialize, SourceEnd, TargetEnd)
import Network.Transport.TCP (mkTransport, TCPConfig (..))

import Control.Monad (forever, replicateM_, forM_)

import qualified Data.Serialize as Ser
import Data.Maybe (fromJust)
import Data.Int
import System.Environment (getArgs, withArgs)
import Data.Time (getCurrentTime, diffUTCTime)
import System.IO (withFile, IOMode(..), hPutStrLn)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)

#ifndef LAZY
import qualified Data.ByteString.Char8 as BS
import qualified Network.Socket.ByteString as NBS
encode = Ser.encode
decode = Ser.decode
#else
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Network.Socket.ByteString.Lazy as NBS
encode = Ser.encodeLazy
decode = Ser.decodeLazy
#endif
{-# INLINE encode #-}
{-# INLINE decode #-}
encode :: Ser.Serialize a => a -> BS.ByteString
decode :: Ser.Serialize a => BS.ByteString -> Either String a



-- | This performs a ping benchmark on the TCP transport. This can be
-- compiled using:
--
--     ghc --make -idistributed-process/src -inetwork-transport/src -O2 benchmarks/PingTransport.hs
--
-- To use the compiled binary, first set up a server:
--
--     ./benchmarks/PingTransport server 0.0.0.0 8080 sourceAddr
--
-- Once this is established, launch a client to perform the benchmark. The
-- following command sends 1000 pings per mark.
--
--     ./benchmarks/PingTransport client 0.0.0.0 8081 sourceAddr 1000
--
-- The server must be restarted between benchmarks.
main :: IO ()
main = do
  [pingsStr] <- getArgs
  serverAddr <- newEmptyMVar
  clientAddr <- newEmptyMVar

  -- Start the server
  forkIO $ do
    -- establish transport
    transport <- mkTransport $ TCPConfig defaultHints "127.0.0.1" "8080" 

    -- create ping end
    putStrLn "server: creating ping end"
    (sourceAddrPing, targetEndPing) <- newConnection transport
    putMVar serverAddr sourceAddrPing

    -- create pong end
    putStrLn "server: creating pong end"
    sourceAddrPong <- takeMVar clientAddr
    sourceEndPong <- connect sourceAddrPong

    -- always respond to a ping with a pong
    putStrLn "server: awaiting pings"
    pong targetEndPing sourceEndPong

  -- Client
  sourceAddr <- takeMVar serverAddr
  let pings = read pingsStr
  -- establish transport
  transport <- mkTransport $ TCPConfig defaultHints "127.0.0.1" "8081" 

  -- create ping end
  sourceEndPing <- connect sourceAddr 

  -- create pong end
  (sourceAddrPong, targetEndPong) <- newConnection transport
  putMVar clientAddr sourceAddrPong

  ping sourceEndPing targetEndPong pings 
  putStrLn "Done with all ping/pongs."

-- | The message we use to ping (CAF so that we don't keep encoding it)
pingMessage :: BS.ByteString
pingMessage = BS.pack "ping123"

-- | Keep replying to pings (send pongs)
pong :: TargetEnd -> SourceEnd -> IO ()
pong targetEndPing sourceEndPong = do
  [bs] <- receive targetEndPing
  -- putStrLn $ "server got " ++ BS.unpack bs
  send sourceEndPong [bs]
  pong targetEndPing sourceEndPong

-- | Send a number of pings
ping :: SourceEnd -> TargetEnd -> Int -> IO ()
ping sourceEndPing targetEndPong pings = go [] pings
  where
    go :: [Double] -> Int -> IO ()
    go rtl 0 = do
      outputData rtl
      putStrLn $ "client did " ++ show pings ++ " pings"
    go rtl !i = do
      before <- getCurrentTime
      send sourceEndPing [pingMessage]
      [bs] <- receive targetEndPong
      -- putStrLn $ "client got " ++ BS.unpack bs
      after <- getCurrentTime
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      latency `seq` go (latency : rtl) (i - 1)

-- | Output latencies to a file to be plotted
outputData :: [Double] -> IO ()
outputData rtl = do
  withFile "round-trip-latency-tcp-transport.data" WriteMode $ \h -> 
    forM_ (zip [0..] rtl) $ \(i, latency) -> 
      hPutStrLn h $ (show i) ++ " " ++ (show latency)
