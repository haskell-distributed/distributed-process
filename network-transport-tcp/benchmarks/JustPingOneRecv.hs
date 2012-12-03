{-# LANGUAGE CPP, BangPatterns #-}

module Main where

import Control.Monad

import Data.Int
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
import Data.ByteString.Internal as BSI
import Foreign.Storable (pokeByteOff, peekByteOff)
import Foreign.C (CInt(..))
import Foreign.ForeignPtr (withForeignPtr)

foreign import ccall unsafe "htonl" htonl :: CInt -> CInt
foreign import ccall unsafe "ntohl" ntohl :: CInt -> CInt

main :: IO ()
main = do
  [pingsStr]  <- getArgs
  serverReady <- newEmptyMVar
  clientDone  <- newEmptyMVar

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

  -- Start the client
  forkIO $ do
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
    putMVar clientDone ()

  -- Wait for the client to finish
  takeMVar clientDone

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
recv sock i = do
  (header, payload) <- BS.splitAt 4 `fmap` NBS.recv sock (4 + i)
  length <- decodeLength header -- Ignored
  return payload

-- | Wrapper around NBS.send (for profiling)
send :: Socket -> ByteString -> IO ()
send sock bs = do
  length <- encodeLength (fromIntegral (BS.length bs))
  NBS.sendMany sock [length, bs]

-- | Encode length (manual for now)
encodeLength :: Int32 -> IO ByteString
encodeLength i32 =
  BSI.create 4 $ \p ->
    pokeByteOff p 0 (htonl (fromIntegral i32))

-- | Decode length (manual for now)
decodeLength :: ByteString -> IO Int32
decodeLength bs =
  let (fp, _, _) = BSI.toForeignPtr bs in
  withForeignPtr fp $ \p -> do
    w32 <- peekByteOff p 0
    return (fromIntegral (ntohl w32))
