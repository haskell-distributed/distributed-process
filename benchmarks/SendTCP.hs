module Main where

import Control.Monad
import Criterion.Main (Benchmark, bench, defaultMain, nfIO, bgroup)
import Data.Binary
import Data.ByteString.Lazy (ByteString)
import Data.Int
import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , defaultHints
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import System.Environment (getArgs, withArgs)

import qualified Data.ByteString.Lazy as BS
import qualified Network.Socket as N
import qualified Network.Socket.ByteString.Lazy as NBS

-- | This performs a benchmark on a TCP connection to measure how long it takes
-- to transfer a number of bytes.
-- To compile this file, you might use:
--
--    ghc --make -idistributed-process/src -inetwork-transport/src -O2 benchmarks/SendTCP.hs
--
-- To use the compiled binary, first set up the server on the current machine,
-- such that it expects 1000 bytes:
--
--     ./benchmarks/SendTCP server 8080 1000
--
-- Next, perform the benchmark on a client using the server address, where
-- each mark is 1000 bytes:
--
--    ./benchmarks/SendTCP client 0.0.0.0 8080 1000
--
-- The server must be restarted between benchmarks.
main :: IO ()
main = do
  args <- getArgs
  case args of
    "server" : service : sizeStr : [] -> withSocketsDo $ do
      let size = read sizeStr
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

      putStrLn "server: listening for data"

      forever $ pong clientSock size

    "client": host : service : sizeStr : args' -> withSocketsDo $ do
      let size = read sizeStr
      serverAddrs <- getAddrInfo 
        Nothing
        (Just host)
        (Just service)
      let serverAddr = head serverAddrs
      sock <- socket (addrFamily serverAddr) Stream defaultProtocol

      N.connect sock (addrAddress serverAddr)

      -- benchmark the data
      let bs = BS.replicate size 0
      withArgs args' $ defaultMain [ benchSend sock bs ]

-- | Each `ping` sends a `ByteString` and expects a byte in return.
ping :: Socket -> ByteString -> IO Word8
ping sock bs = do
  NBS.send sock bs
  bs' <- NBS.recv sock 1
  return $ decode bs

pong :: Socket -> Int64 -> IO ()
pong sock size = do
  bs <- NBS.recv sock size
  NBS.sendAll sock (encode (0 :: Word8))
  return ()

benchSend :: Socket -> ByteString -> Benchmark
benchSend sock bs = bench "SendTCP" $
  nfIO (ping sock bs)
