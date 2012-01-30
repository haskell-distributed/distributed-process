module Main where

import Network.Transport
import Network.Transport.TCP (mkTransport, TCPConfig (..))

import Control.Monad (forever)
import Criterion.Main (Benchmark, bench, defaultMain, nfIO)
import Data.Binary
import Data.Maybe (fromJust)
import Data.Int
import System.Environment (getArgs, withArgs)

import qualified Data.ByteString.Lazy.Char8 as BS

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
  args <- getArgs
  case args of
    "server" : host : service : sourceAddrFilePath : [] -> do
      -- establish transport
      transport <- mkTransport $ TCPConfig defaultHints host service

      -- create ping end
      putStrLn "server: creating ping end"
      (sourceAddrPing, targetEndPing) <- newConnection transport
      BS.writeFile sourceAddrFilePath $ serialize sourceAddrPing

      -- create pong end
      putStrLn "server: creating pong end"
      [sourceAddrPongBS] <- receive targetEndPing
      sourceEndPong <- connect . fromJust $ deserialize transport sourceAddrPongBS

      -- always respond to a ping with a pong
      putStrLn "server: awaiting pings"
      forever $ pong targetEndPing sourceEndPong


    "client" : host : service : sourceAddrFilePath : pingsStr : args' -> do
      let pings = read pingsStr
      -- establish transport
      transport <- mkTransport $ TCPConfig defaultHints host service

      -- create ping end
      sourceAddrPingBS <- BS.readFile sourceAddrFilePath
      sourceEndPing <- connect . fromJust $ deserialize transport sourceAddrPingBS

      -- create pong end
      (sourceAddrPong, targetEndPong) <- newConnection transport
      send sourceEndPing [serialize sourceAddrPong]

      -- benchmark the pings
      withArgs args' $ defaultMain [ benchPing sourceEndPing targetEndPong pings]

-- | This function takes a `TargetEnd` for the pings, and a `SourceEnd` for
-- pongs. Whenever a ping is received from the `TargetEnd`, a pong is sent
-- in reply down the `SourceEnd`, repeating whatever was sent.
pong :: TargetEnd -> SourceEnd -> IO ()
pong targetEndPing sourceEndPong = do
  bs <- receive targetEndPing
  send sourceEndPong bs

-- | The effect of `ping sourceEndPing targetEndPong n` is to send the number
-- `n` using `sourceEndPing`, and to then receive the a number from
-- `targetEndPong`, which is then returned.
ping :: SourceEnd -> TargetEnd -> Int64 -> IO Int64
ping sourceEndPing targetEndPong n = do
  send sourceEndPing [encode n]
  [bs] <- receive targetEndPong
  return $ decode bs

-- | The effect of `benchPing sourceEndPing targetEndPong n` is to send
-- `n` pings down `sourceEndPing` using the `ping` function. The time
-- taken is benchmarked.
benchPing :: SourceEnd -> TargetEnd -> Int64 -> Benchmark
benchPing sourceEndPing targetEndPong n = bench "Transport Ping" $
  nfIO (mapM_ (ping sourceEndPing targetEndPong) [1 .. n])

