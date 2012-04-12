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

main :: IO ()
main = do
  [pingsStr] <- getArgs
  serverReady <- newEmptyMVar

  -- Start the server
  forkIO $ do
    putStrLn "server: creating TCP connection"
    serverAddrs <- getAddrInfo 
      (Just (defaultHints { addrFlags = [AI_PASSIVE] } ))
      Nothing
      (Just "8080")
    let serverAddr = head serverAddrs
    sock <- socket (addrFamily serverAddr) Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (addrAddress serverAddr)

    putStrLn "server: awaiting client connection"
    putMVar serverReady ()
    listen sock 1
    (clientSock, clientAddr) <- accept sock

    putStrLn "server: listening for pings"
    pong clientSock

  -- Client
  takeMVar serverReady
  let pings = read pingsStr
  serverAddrs <- getAddrInfo 
    Nothing
    (Just "127.0.0.1")
    (Just "8080")
  let serverAddr = head serverAddrs
  sock <- socket (addrFamily serverAddr) Stream defaultProtocol

  N.connect sock (addrAddress serverAddr)

  ping sock pings

pingMessage :: ByteString
pingMessage = pack "ping123"

ping :: Socket -> Int -> IO () 
ping sock pings = go pings
  where
    go :: Int -> IO ()
    go 0 = do 
      putStrLn $ "client did " ++ show pings ++ " pings"
    go !i = do
      before <- getCurrentTime
      send sock pingMessage 
      bs <- recv sock 8
      after <- getCurrentTime
      -- putStrLn $ "client received " ++ unpack bs
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      hPutStrLn stderr $ show i ++ " " ++ show latency 
      go (i - 1)

pong :: Socket -> IO ()
pong sock = do
  bs <- recv sock 8
  -- putStrLn $ "server received " ++ unpack bs
  when (BS.length bs > 0) $ do
    send sock bs
    pong sock

-- | Wrapper around NBS.recv (for profiling) 
recv :: Socket -> Int -> IO ByteString
recv sock _ = do
  header <- NBS.recv sock 4
  let Right length = Ser.decode header 
  NBS.recv sock (fromIntegral (length :: Int32))

-- | Wrapper around NBS.send (for profiling)
send :: Socket -> ByteString -> IO () 
send sock bs = do
  let length :: Int32
      length = fromIntegral $ BS.length bs
  NBS.sendMany sock [Ser.encode length, bs]
