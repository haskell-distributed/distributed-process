module Main where

import Network.Transport
import Network.Transport.Internal (encodeInt32, decodeInt32, prependLength)
import Network.Transport.Internal.TCP (recvExact, sendMany)
import Network.Transport.TCP (createTransport, decodeEndPointAddress, EndPointId)
import TestTransport (testTransport)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, readMVar)
import Control.Concurrent (forkIO)
import Control.Monad.Trans.Maybe (runMaybeT)
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
                                     , HostName
                                     , ServiceName
                                     )

testEarlyDisconnect :: IO ()
testEarlyDisconnect = do
  return ()
{-
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
      runMaybeT $ sendMany sock (encodeInt32 endPointIx : prependLength [myAddress])
  
      -- Request a new connection
      runMaybeT $ do
        sendInt32 sock 0
        [connBs] <- recvExact sock 2
        decodeInt16 connBs
  
      -- Close the socket without closing the connection explicitly
      -- The server should still receive a ConnectionClosed message
      N.sClose sock
-}

testInvalidAddress :: IO ()
testInvalidAddress = do
  Left err <- createTransport "invalidHostName" "8082"
  putStrLn $ "Got expected error: " ++ show err

testInvalidConnect :: IO ()
testInvalidConnect = do
  Right transport <- createTransport "127.0.0.1" "8083"
  Right endpoint <- newEndPoint transport

  -- Syntax error in the endpoint address
  Left (FailedWith ConnectInvalidAddress err1) <- 
    connect endpoint (EndPointAddress "InvalidAddress") ReliableOrdered
  putStrLn $ "Got expected error: " ++ show err1
 
  -- Syntax connect, but invalid hostname (TCP address lookup failure)
  Left (FailedWith ConnectInvalidAddress err2) <- 
    connect endpoint (EndPointAddress "invalidHost:port:0") ReliableOrdered
  putStrLn $ "Got expected error: " ++ show err2
 
  -- TCP address correct, but nobody home at that address
  Left (FailedWith ConnectFailed err3) <- 
    connect endpoint (EndPointAddress "127.0.0.1:9000:0") ReliableOrdered
  putStrLn $ "Got expected error: " ++ show err3
 
  -- Valid TCP address but invalid endpoint number
  {-
  Left (FailedWith ConnectFailed err4) <- 
    connect endpoint (EndPointAddress "127.0.0.1:8083:1") ReliableOrdered
  putStrLn $ "Got expected error: " ++ show err4
  -}

main :: IO ()
main = do
  testEarlyDisconnect
  testInvalidAddress
  testInvalidConnect
  Right transport <- createTransport "127.0.0.1" "8080" 
  testTransport transport 
