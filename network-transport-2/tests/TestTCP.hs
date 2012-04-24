module Main where

import Network.Transport
import Network.Transport.Internal (encodeInt16, decodeInt16)
import Network.Transport.Internal.TCP ( sendWithLength
                                      , recvExact
                                      , sendInt32
                                      )
import Network.Transport.TCP (createTransport, decodeEndPointAddress, EndPointId)
import TestTransport (testTransport)
import System.Exit (exitFailure, exitSuccess)
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
    serverAddr <- newEmptyMVar
    serverDone <- newEmptyMVar
    transport  <- createTransport "127.0.0.1" "8081" 
 
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
      endPointBS <- encodeInt16 (fromIntegral endPointIx)
      runMaybeT $ sendWithLength sock (Just endPointBS) [myAddress]
  
      -- Request a new connection
      connIx <- runMaybeT $ do
        sendInt32 sock 0
        [connBs] <- recvExact sock 2
        decodeInt16 connBs
  
      -- Close the socket without closing the connection explicitly
      -- The server should still receive a ConnectionClosed message
      N.sClose sock

main :: IO ()
main = do
  testEarlyDisconnect
  success <- createTransport "127.0.0.1" "8080" >>= testTransport 
  if success then exitSuccess else exitFailure
