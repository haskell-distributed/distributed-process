module Main where

import Network.Transport
import Network.Transport.Internal (encodeInt16)
import Network.Transport.Internal.TCP (sendWithLength)
import TestTransport (testTransport)
import Network.Transport.TCP (createTransport, decodeEndPointAddress)
import System.Exit (exitFailure, exitSuccess)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, readMVar)
import Control.Concurrent (forkIO)
import Control.Applicative ((<$>), pure)
import Data.Maybe (fromJust)
import qualified Network.Socket as N ( getAddrInfo
                                     , socket
                                     , connect
                                     , addrFamily
                                     , addrAddress
                                     , SocketType(Stream)
                                     , SocketOption(ReuseAddr)
                                     , defaultProtocol
                                     , setSocketOption
                                     , sClose
                                     )
import qualified Network.Socket.ByteString as NBS (sendMany)                                     

testEarlyDisconnect :: IO ()
testEarlyDisconnect = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar
  transport  <- createTransport "127.0.0.1" "8080" 
  
  -- Server
  forkIO $ do 
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)

    -- Wait for an incoming connection
    ConnectionOpened _ _ _ <- receive endpoint

    -- Wait for the client to disconnect
    ConnectionClosed _ <- receive endpoint

    putMVar serverDone ()

  -- Client
  --
  -- We manually connect to the server to request a new connection,
  -- but then close the socket before the server gets the chance to
  -- respond
  forkIO $ do
    Right endpoint <- newEndPoint transport
    let EndPointAddress myAddress = address endpoint

    -- Connect to the server
    addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8080")
    sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
    N.setSocketOption sock N.ReuseAddr 1
    N.connect sock (N.addrAddress addr)

    -- Send number of the destination endpoint and our own address 
    (_, _, endPointIx) <- readMVar serverAddr
    endPointBS <- encodeInt16 (fromIntegral endPointIx)
    sendWithLength sock (Just endPointBS) [myAddress]

    -- Request a new connection
    pure <$> encodeInt16 0 >>= NBS.sendMany sock

    -- At this point the server will try to reply with the connection ID,
    -- but we close the connection instead
    N.sClose sock

  -- Wait for the server to finish
  takeMVar serverDone

main :: IO ()
main = do
  success <- createTransport "127.0.0.1" "8080" >>= testTransport 
  if success then exitSuccess else exitFailure
  -- testEarlyDisconnect
