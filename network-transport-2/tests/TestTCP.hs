module Main where

import TestTransport 
import Network.Transport
import Network.Transport.Internal (encodeInt32, prependLength)
import Network.Transport.Internal.TCP (recvInt32)
import Network.Transport.TCP (createTransport, decodeEndPointAddress, EndPointId, ControlHeader(..))
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, readMVar)
import Control.Concurrent (forkIO)
import Data.Maybe (fromJust)
import Data.Int (Int32)
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
                                     , HostName
                                     , ServiceName
                                     )
import Network.Socket.ByteString (sendMany)                                     

testEarlyDisconnect :: IO ()
testEarlyDisconnect = do
    serverAddr <- newEmptyMVar
    serverDone <- newEmptyMVar
    Right transport  <- createTransport "127.0.0.1" "8081" 
 
    forkIO $ server transport serverAddr serverDone
    forkIO $ client transport serverAddr 

    takeMVar serverDone
  where
    server :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> MVar () -> IO ()
    server transport serverAddr serverDone = do
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)
      ConnectionOpened _ _ _ <- receive endpoint
      ConnectionClosed _ <- receive endpoint
      putMVar serverDone ()

    client :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> IO ()
    client transport serverAddr = do
      Right endpoint <- newEndPoint transport
      let EndPointAddress myAddress = address endpoint
  
      -- Connect to the server
      addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8081")
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr)
  
      (_, _, endPointIx) <- readMVar serverAddr
      sendMany sock (encodeInt32 endPointIx : prependLength [myAddress])

      -- Wait for acknowledgement
      ValidEndPoint <- recvInt32 sock
  
      -- Request a new connection, but don't wait for the response
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
  
      -- Close the socket without closing the connection explicitly
      -- The server should still receive a ConnectionClosed message
      N.sClose sock

testInvalidAddress :: IO ()
testInvalidAddress = do
  Left _ <- createTransport "invalidHostName" "8082"
  return ()

testInvalidConnect :: IO ()
testInvalidConnect = do
  Right transport <- createTransport "127.0.0.1" "8083"
  Right endpoint <- newEndPoint transport

  -- Syntax error in the endpoint address
  Left (FailedWith ConnectInvalidAddress _) <- 
    connect endpoint (EndPointAddress "InvalidAddress") ReliableOrdered
 
  -- Syntax connect, but invalid hostname (TCP address lookup failure)
  Left (FailedWith ConnectInvalidAddress _) <- 
    connect endpoint (EndPointAddress "invalidHost:port:0") ReliableOrdered
 
  -- TCP address correct, but nobody home at that address
  Left (FailedWith ConnectFailed _) <- 
    connect endpoint (EndPointAddress "127.0.0.1:9000:0") ReliableOrdered
 
  -- Valid TCP address but invalid endpoint number
  Left (FailedWith ConnectInvalidAddress _) <- 
    connect endpoint (EndPointAddress "127.0.0.1:8083:1") ReliableOrdered

  return ()

main :: IO ()
main = do
  runTestIO "EarlyDisconnect" testEarlyDisconnect
  runTestIO "InvalidAddress" testInvalidAddress
  runTestIO "InvalidConnect" testInvalidConnect
  Right transport <- createTransport "127.0.0.1" "8080" 
  testTransport transport 
