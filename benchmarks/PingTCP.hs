{-# LANGUAGE CPP, BangPatterns #-}

module Main where

import Control.Monad

import Data.Int
import qualified Data.Serialize as Ser
import Data.Word (Word8)
import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , defaultHints
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import System.Environment (getArgs, withArgs)
import Data.Time (getCurrentTime, diffUTCTime, NominalDiffTime)
import System.IO (withFile, IOMode(..), hPutStrLn)

import qualified Network.Socket as N

import Debug.Trace

#ifndef LAZY
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import qualified Data.ByteString as BS
import qualified Network.Socket.ByteString as NBS
encode = Ser.encode
decode = Ser.decode
#else
import Data.ByteString.Lazy (ByteString, pack)
import qualified Network.Socket.ByteString.Lazy as NBS
encode = Ser.encodeLazy
decode = Ser.decodeLazy
#endif
{-# INLINE encode #-}
{-# INLINE decode #-}
encode :: Ser.Serialize a => a -> ByteString
decode :: Ser.Serialize a => ByteString -> Either String a

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
      pong clientSock

    "client": host : service : pingsStr : [] -> withSocketsDo $ do
      let pings = read pingsStr
      serverAddrs <- getAddrInfo 
        Nothing
        (Just host)
        (Just service)
      let serverAddr = head serverAddrs
      sock <- socket (addrFamily serverAddr) Stream defaultProtocol

      N.connect sock (addrAddress serverAddr)

      ping sock pings

pingMessage :: ByteString
pingMessage = pack "ping123"

ping :: Socket -> Int -> IO () 
ping sock pings = go [] pings
  where
    go :: [Double] -> Int -> IO ()
    go rtl 0 = do 
      withFile "round-trip-latency-tcp.data" WriteMode $ \h -> 
        forM_ (zip [0..] rtl) $ \(i, latency) -> 
          hPutStrLn h $ (show i) ++ " " ++ (show latency)
      putStrLn $ "client did " ++ show pings ++ " pings"
    go rtl !i = do
      before <- getCurrentTime
      NBS.send sock pingMessage 
      bs <- NBS.recv sock 8
      after <- getCurrentTime
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      latency `seq` go (latency : rtl) (i - 1)

pong :: Socket -> IO ()
pong sock = do
  bs <- NBS.recv sock 8
  when (BS.length bs > 0) $ do
    NBS.sendAll sock bs
    pong sock
