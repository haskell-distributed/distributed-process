{-# LANGUAGE CPP #-}



-- | This performs a ping benchmark on the TCP transport. If
-- network-transport-tcp has been "cabal install"ed, then this
-- benchmark can be compiled with:
--
--     ghc --make -O2 benchmarks/PingTransport.hs
--
-- To use the compiled binary, first set up a server:
--
--     ./benchmarks/PingTCPTransport server 0.0.0.0 8080 sourceAddr.dat
--
-- Once this is established, launch a client to perform the benchmark. The
-- following command sends 1000 pings for 1 trial:
--
--     ./benchmarks/PingTCPTransport client 0.0.0.0 8081 sourceAddr.dat 1000 1 
--
-- The server must be restarted between benchmarks.

--------------------------------------------------------------------------------
module Main where

import Network.Transport (receive, connect, send, defaultConnectHints, Event(..),
			  Connection, EndPoint, EndPointAddress(EndPointAddress), Reliability(ReliableOrdered),
                          newEndPoint, address, endPointAddressToByteString)
import Network.Transport.TCP (createTransport, defaultTCPParameters, decodeEndPointAddress)

import Control.Monad (forever, replicateM_)
import Criterion.Main (Benchmark, bench, defaultMainWith, nfIO)
import Criterion.Config (defaultConfig, ljust, Config(cfgSamples))

import qualified Data.Serialize as Ser
import Data.Maybe (fromJust)
import Data.Int
import System.Environment (getArgs, withArgs)

import System.Exit (exitSuccess)

#ifndef LAZY
import qualified Data.ByteString.Char8 as BS
encode = Ser.encode
decode = Ser.decode
#else
import qualified Data.ByteString.Lazy.Char8 as BS
encode = Ser.encodeLazy
decode = Ser.decodeLazy
#endif
{-# INLINE encode #-}
{-# INLINE decode #-}
encode :: Ser.Serialize a => a -> BS.ByteString
decode :: Ser.Serialize a => BS.ByteString -> Either String a

--------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    "server" : host : port : sourceAddrFilePath : [] -> do
      -- establish transport
      Right transport <- createTransport host port defaultTCPParameters

      -- create ping end
      putStrLn "server: creating ping end"
--      (sourceAddrPing, targetEndPing)
      Right endpoint <- newEndPoint transport
      BS.writeFile sourceAddrFilePath $ endPointAddressToByteString $ address endpoint

      -- create pong end
      putStrLn "server: creating pong end"
      -- Establish the connection:
      event <- receive endpoint
      Right conn <- case event of 
        ConnectionOpened cid rel addr -> 
          -- Connect right back, and since this is a single-client
          -- benchmark, block this thread to do it:
          connect endpoint addr rel defaultConnectHints
        oth -> do putStrLn$" server waiting for connection, unexpected event: "++show oth
                  exitSuccess
          
      putStrLn "server: going into pong loop..."
      forever $ pong endpoint conn
      return ()
      
    "client" : host : port : sourceAddrFilePath : numPings : reps : args' -> do
      let pings = read numPings :: Int
      -- establish transport
      Right transport <- createTransport host port defaultTCPParameters
      Right endpoint <- newEndPoint transport
      
      -- create ping end
      bs <- BS.readFile sourceAddrFilePath
      Right conn <- connect endpoint (EndPointAddress bs) ReliableOrdered defaultConnectHints
--      let Just (host,port,endptID) = decodeEndPointAddress (EndPointAddress bs)
      -- create pong end
--      send sourceEndPing [serialize sourceAddrPong]

      -- benchmark the pings
      case (read reps) :: Int of
        0 -> error "Error: What would zero trials mean?"
        1 -> do putStrLn "Because you're timing only one trial, skipping Criterion..."
                replicateM_ pings (ping conn endpoint 42)
        n -> withArgs args' $ defaultMainWith 
                               (defaultConfig{ cfgSamples = ljust n })
			       (return ()) -- Init action.
	                       [ benchPing conn endpoint (fromIntegral pings)]

      putStrLn$"client: Done with all "++show pings++" ping/pongs."
      return ()

-- | This function takes an EndPoint to receieve pings, and a
-- Connection to send back pongs.  It doesn't bother decoding the
-- message, rather it sends it right on back.
pong :: EndPoint -> Connection -> IO ()
pong endpoint conn = do
  event <- receive endpoint
  case event of 
    Received cid payloads -> do 
      Right _ <- send conn payloads
      return ()
    oth -> error$"while awaiting pings, server received unexpected event: \n"++show oth

-- | The effect of `ping conn endpt n` is to send the number `n` on
-- the connection and then receive another number from the endpoint,
-- which is then returned.  
ping :: Connection -> EndPoint -> Int64 -> IO Int64
ping conn endpt n = do
  send conn [encode n]
  loop
 where 
  loop = do 
    event <- receive endpt
    case event of 
      Received _cid [payload] -> do 
        let (Right n2) = decode payload
        return $! n2
      ConnectionOpened _ _ _ -> loop -- ignore this
      other -> error$"Unexpected event on endpoint during ping process: "++show other

-- | The effect of `benchPing conn endpt n` is to send
-- `n` pings down `conn` using the `ping` function. 
benchPing :: Connection -> EndPoint -> Int64 -> Benchmark
benchPing conn endpoint n = bench "PingTransport" $
  nfIO (replicateM_ (fromIntegral n) (ping conn endpoint 42))
