module Main where

import Network.Transport
import Network.Transport.Internal (encodeInt16, decodeInt16)
import Network.Transport.Internal.TCP (sendWithLength, recvExact, sendMany)
import TestTransport (testTransport)
import Network.Transport.TCP (createTransport, decodeEndPointAddress)
import System.Exit (exitFailure, exitSuccess)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, readMVar)
import Control.Concurrent (forkIO)
-- import Control.Monad.IO.Class (liftIO)
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
                                     )

testEarlyDisconnect :: IO ()
testEarlyDisconnect = do
  serverAddr <- newEmptyMVar
  serverDone <- newEmptyMVar
  transport  <- createTransport "127.0.0.1" "8080" 
  
  -- Server
  forkIO $ do 
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)

    putStrLn "Server waiting for client to connect"

    -- Wait for an incoming connection
    ConnectionOpened _ _ _ <- receive endpoint

    putStrLn "Server waiting for client to disconnect"

    -- Wait for the client to disconnect
    ConnectionClosed _ <- receive endpoint

    putStrLn "Server exiting"

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

    (_, _, endPointIx) <- readMVar serverAddr
    endPointBS <- encodeInt16 (fromIntegral endPointIx)
    runMaybeT $ sendWithLength sock (Just endPointBS) [myAddress]

    -- Request a new connection
    zero <- encodeInt16 0 
    runMaybeT $ sendMany sock [zero]

    -- Request a new connection
    connIx <- runMaybeT $ do
      [connBs] <- recvExact sock 2
      decodeInt16 connBs
    putStrLn $ "Client got connection ID " ++ show connIx

    -- Close the socket 
    N.sClose sock

  -- Wait for the server to finish
  takeMVar serverDone

main :: IO ()
main = do
  success <- createTransport "127.0.0.1" "8080" >>= testTransport 
  if success then exitSuccess else exitFailure
  -- testEarlyDisconnect
