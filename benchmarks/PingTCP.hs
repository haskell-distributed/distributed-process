module Main where

import Control.Monad
import Criterion.Main (Benchmark, bench, defaultMain, nfIO, bgroup)
import Data.Binary
import Data.Int
import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , defaultHints
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import System.Environment (getArgs, withArgs)

import qualified Network.Socket as N
import qualified Network.Socket.ByteString.Lazy as NBS

import Debug.Trace

-- | This performs a ping benchmark on a TCP connection created by
-- Network.Socket. To compile this file, you might use:
--
--    ghc --make -idistributed-process/src -inetwork-transport/src -O2 benchmarks/PingTCP.hs
--
-- To use the compiled binary, first set up the server on the current machine:
--
--     ./benchmarks/PingTCP server 8080
--
-- Next, perform the benchmark on a client using the server address, where
-- each mark is 1000 pings:
--
--    ./benchmarks/PingTCP client 0.0.0.0 8080 1000
--
-- The server must be restarted between benchmarks.
main :: IO ()
main = do
  args <- getArgs
  case args of
    "server" : service : [] -> withSocketsDo $ do
      putStrLn "server: creating TCP connection"
      serverAddrs <- getAddrInfo 
        (Just (defaultHints { addrFlags = [AI_PASSIVE] } ))
        Nothing
        (Just service)
      let serverAddr = head serverAddrs
      sock <- socket (addrFamily serverAddr) Stream defaultProtocol
      setSocketOption sock ReuseAddr 1
      bindSocket sock (addrAddress serverAddr)

      putStrLn "server: awaiting client connection"
      listen sock 1
      (clientSock, clientAddr) <- accept sock

      putStrLn "server: listening for pings"
      forever (pong clientSock)

    "client": host : service : pingsStr : args' -> withSocketsDo $ do
      let pings = read pingsStr
      serverAddrs <- getAddrInfo 
        Nothing
        (Just host)
        (Just service)
      let serverAddr = head serverAddrs
      sock <- socket (addrFamily serverAddr) Stream defaultProtocol

      N.connect sock (addrAddress serverAddr)

      -- benchmark the pings
      withArgs args' $ defaultMain [ benchPing sock pings ]

-- | Each `ping` sends a single byte, and expects to receive one
-- back in return.
ping :: Socket -> IO Word8
ping sock = do
  NBS.send sock $ encode (0 :: Word8)
  bs <- NBS.recv sock 1
  return $ decode bs

pong :: Socket -> IO ()
pong sock = do
  bs <- NBS.recv sock 1
  NBS.sendAll sock bs
  return ()

benchPing :: Socket -> Int64 -> Benchmark
benchPing sock n = bench "PingTCP" $
  nfIO (replicateM_ (fromIntegral n) (ping sock))

