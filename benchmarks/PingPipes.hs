module Main where

-- TODO: Merge with PingTCPTransport and factor differences.

import Network.Transport (newConnection, receive, connect, send,
			  serialize, deserialize, SourceEnd, TargetEnd)
import Network.Transport.Pipes (mkTransport)

import Control.Monad (forever, replicateM_)
import Criterion.Main (Benchmark, bench, defaultMainWith, nfIO)
import Criterion.Config (defaultConfig, ljust, Config(cfgSamples))
-- import Data.Binary (encode,decode)
import Data.Serialize (encode,decode)
import Data.Maybe (fromJust)
import Data.Int
import System.Environment (getArgs, withArgs)

-- import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Char8 as BS

-- | This performs a ping benchmark on the TCP transport. This can be
-- compiled using:
--
--     ghc --make -idistributed-process/src -inetwork-transport/src -O2 benchmarks/PingTransport.hs
--
-- To use the compiled binary, first set up a server:
--
--     ./benchmarks/PingPipes server sourceAddr
--
-- Once this is established, launch a client to perform the benchmark. The
-- following command sends 1000 pings per mark.
--
--     ./benchmarks/PingPipes client sourceAddr 1000
--
-- The server must be restarted between benchmarks.
main :: IO ()
main = do
  args <- getArgs
  case args of
    "server" : sourceAddrFilePath : [] -> do
      -- establish transport
      transport <- mkTransport 

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


    "client" : sourceAddrFilePath : pingsStr : reps : args' -> do
      let pings = read pingsStr
      -- establish transport
      transport <- mkTransport 

      -- create ping end
      sourceAddrPingBS <- BS.readFile sourceAddrFilePath
      sourceEndPing <- connect . fromJust $ deserialize transport sourceAddrPingBS

      -- create pong end
      (sourceAddrPong, targetEndPong) <- newConnection transport
      send sourceEndPing [serialize sourceAddrPong]

      -- benchmark the pings
      case (read reps) :: Int of
        0 -> error "What would zero reps mean?"
        1 -> do putStrLn "Because you're timing only one trial, skipping Criterion..."
                replicateM_ pings (ping sourceEndPing targetEndPong)
        n -> withArgs args' $ defaultMainWith 
                               (defaultConfig{ cfgSamples = ljust n })
			       (return ()) -- Init action.
	                       [ benchPing sourceEndPing targetEndPong (fromIntegral pings) ]
      putStrLn "Done with all ping/pongs."


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
ping :: SourceEnd -> TargetEnd -> IO Int64
ping sourceEndPing targetEndPong = do
  -- send sourceEndPing [BS.empty]
  send sourceEndPing [encode (42 :: Int64)]

  [bs] <- receive targetEndPong
--  return $ decode bs
  case decode bs of 
    Left err -> error$ "decode failure: " ++ err
    Right x  -> return x

-- | The effect of `benchPing sourceEndPing targetEndPong n` is to send
-- `n` pings down `sourceEndPing` using the `ping` function. The time
-- taken is benchmarked.
benchPing :: SourceEnd -> TargetEnd -> Int64 -> Benchmark
benchPing sourceEndPing targetEndPong n = bench "PingTransport" $
  nfIO (replicateM_ (fromIntegral n) (ping sourceEndPing targetEndPong))

