{-# LANGUAGE RebindableSyntax #-}
module Main where

import Prelude hiding (catch, (>>=), (>>), return, fail)
import TestTransport (testTransport) 
import TestAuxiliary (forkTry, runTests)
import Network.Transport
import Network.Transport.TCP (createTransport, encodeEndPointAddress)
import Data.Int (Int32)
import Data.Maybe (fromJust)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, readMVar, isEmptyMVar)
import Control.Monad (replicateM)
import Control.Applicative ((<$>))
import Network.Transport.TCP ( decodeEndPointAddress
                             , EndPointId
                             , ControlHeader(..)
                             , ConnectionRequestResponse(..)
                             )
import Network.Transport.Internal (encodeInt32, prependLength, tlog, tryIO)
import Network.Transport.Internal.TCP (recvInt32)
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
import Data.String (fromString)
import Traced 

instance Show (MVar a) where
  show _ = "<<mvar>>"

instance Show EndPoint where
  show _ = "<<endpoint>>"

instance Show Transport where
  show _ = "<<transport>>"

instance Show Connection where
  show _ = "<<connection>>"

trlog :: String -> Traced ()
trlog = liftIO . tlog

-- Test that the server gets a ConnectionClosed message when the client closes
-- the socket without sending an explicit control message to the server first
testEarlyDisconnect :: IO ()
testEarlyDisconnect = do
    clientAddr <- newEmptyMVar
    serverAddr <- newEmptyMVar
    serverDone <- newEmptyMVar

    tlog "testEarlyDisconnect"
    forkTry $ server serverAddr clientAddr serverDone
    forkTry $ client serverAddr clientAddr

    takeMVar serverDone
  where
    server :: MVar (N.HostName, N.ServiceName, EndPointId) -> MVar EndPointAddress -> MVar () -> IO ()
    server serverAddr clientAddr serverDone = do
      tlog "Server"
      Right transport  <- createTransport "127.0.0.1" "8081" 
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)
      theirAddr <- readMVar clientAddr

      runTraced $ do
        -- First test: they connect to us, then drop the connection
        ConnectionOpened cid _ addr <- liftIO $ receive endpoint 
        True <- return $ addr == theirAddr
        
        ErrorEvent (ErrorEventConnectionLost addr [cid']) <- liftIO $ receive endpoint 
        True <- return $ addr == theirAddr && cid' == cid

        -- Second test: after they dropped their connection to us, we now try to
        -- establish a connection to them. This should re-establish the broken
        -- TCP connection. 
        trlog "Trying to connect to client"
        Right conn <- liftIO $ connect endpoint theirAddr ReliableOrdered 


        return ()

      putMVar serverDone ()

{-
      -- To test the connection, we do a simple ping test; as before, however,
      -- the remote client won't close the connection nicely but just closes
      -- the socket
      do
        send conn ["ping"]
        cid <- expect endpoint (\(ConnectionOpened cid _ addr) -> (addr == theirAddr, cid))
        expect' endpoint (\(Received cid' [msg]) -> cid' == cid && msg == "pong") 
        expect' endpoint (\(ErrorEvent (ErrorEventConnectionLost addr [cid'])) -> addr == theirAddr && cid' == cid)

      -- TODO: we now need to decide (and test) and should happen on a subsequent 'send'

-}
      


    client :: MVar (N.HostName, N.ServiceName, EndPointId) -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"
      let  ourAddress = encodeEndPointAddress "127.0.0.1" "8082" 0 
      putMVar clientAddr ourAddress 
      (_, _, endPointIx) <- readMVar serverAddr
 
        
 
      -- Connect to the server
      addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8081")
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr)
  
      sendMany sock (encodeInt32 endPointIx : prependLength [endPointAddressToByteString ourAddress])

      -- Wait for acknowledgement
      ConnectionRequestAccepted <- toEnum <$> recvInt32 sock
  
      -- Request a new connection, but don't wait for the response
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
  
      -- Close the socket without closing the connection explicitly
      -- The server should still receive a ConnectionClosed message
      N.sClose sock

-- | Test the creation of a transport with an invalid address
testInvalidAddress :: IO ()
testInvalidAddress = do
  Left _ <- createTransport "invalidHostName" "8082"
  return ()

-- | Test connecting to invalid or non-existing endpoints
testInvalidConnect :: IO ()
testInvalidConnect = runTraced $ do
  Right transport <- liftIO $ createTransport "127.0.0.1" "8083"
  Right endpoint  <- liftIO $ newEndPoint transport

  -- Syntax error in the endpoint address
  Left (FailedWith ConnectInvalidAddress _) <- liftIO $ 
    connect endpoint (EndPointAddress "InvalidAddress") ReliableOrdered
 
  -- Syntax connect, but invalid hostname (TCP address lookup failure)
  Left (FailedWith ConnectInvalidAddress _) <- liftIO $
    connect endpoint (EndPointAddress "invalidHost:port:0") ReliableOrdered
 
  -- TCP address correct, but nobody home at that address
  Left (FailedWith ConnectFailed _) <- liftIO $
    connect endpoint (EndPointAddress "127.0.0.1:9000:0") ReliableOrdered
 
  -- Valid TCP address but invalid endpoint number
  Left (FailedWith ConnectInvalidAddress _) <- liftIO $
    connect endpoint (EndPointAddress "127.0.0.1:8083:1") ReliableOrdered

  return ()

-- | Test that an endpoint can ignore CloseSocket requests (in "reality" this
-- would happen when the endpoint sends a new connection request before
-- receiving an (already underway) CloseSocket request) 
testIgnoreCloseSocket :: IO ()
testIgnoreCloseSocket = do
    serverAddr <- newEmptyMVar
    clientDone <- newEmptyMVar
    Right transport <- createTransport "127.0.0.1" "8084"
  
    forkTry $ server transport serverAddr
    forkTry $ client transport serverAddr clientDone 
  
    takeMVar clientDone

  where
    server :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> IO ()
    server transport serverAddr = do
      tlog "Server"
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)

      -- Wait for the client to connect and disconnect
      tlog "Waiting for ConnectionOpened"
      ConnectionOpened _ _ _ <- receive endpoint
      tlog "Waiting for ConnectionClosed"
      ConnectionClosed _ <- receive endpoint

      -- At this point the server will have sent a CloseSocket request to the
      -- client, which however ignores it, instead it requests and closes
      -- another connection
      tlog "Waiting for ConnectionOpened"
      ConnectionOpened _ _ _ <- receive endpoint
      tlog "Waiting for ConnectionClosed"
      ConnectionClosed _ <- receive endpoint

      
      tlog "Server waiting.."

    client :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> MVar () -> IO ()
    client transport serverAddr clientDone = do
      tlog "Client"
      Right endpoint <- newEndPoint transport
      let EndPointAddress myAddress = address endpoint

      -- Connect to the server
      addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8084")
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr)

      tlog "Connecting to endpoint"
      (_, _, endPointIx) <- readMVar serverAddr
      sendMany sock (encodeInt32 endPointIx : prependLength [myAddress])

      -- Wait for acknowledgement
      ConnectionRequestAccepted <- toEnum <$> recvInt32 sock

      -- Request a new connection
      tlog "Requesting connection"
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
      response <- replicateM 4 $ recvInt32 sock :: IO [Int32] 

      -- Close the connection again
      tlog "Closing connection"
      sendMany sock [encodeInt32 CloseConnection, encodeInt32 (response !! 3)] 

      -- Server will now send a CloseSocket request as its refcount reached 0
      tlog "Waiting for CloseSocket request"
      CloseSocket <- toEnum <$> recvInt32 sock

      -- But we ignore it and request another connection
      tlog "Ignoring it, requesting another connection"
      let reqId' = 1 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId']
      response' <- replicateM 4 $ recvInt32 sock :: IO [Int32] 

      -- Close it again
      tlog "Closing connection"
      sendMany sock [encodeInt32 CloseConnection, encodeInt32 (response' !! 3)] 

      -- We now get a CloseSocket again, and this time we heed it
      tlog "Waiting for second CloseSocket request"
      CloseSocket <- toEnum <$> recvInt32 sock
    
      tlog "Closing socket"
      sendMany sock [encodeInt32 CloseSocket]
      N.sClose sock

      putMVar clientDone ()

-- | Like 'testIgnoreSocket', but now the server requests a connection after the
-- client closed their connection. In the meantime, the server will have sent a
-- CloseSocket request to the client, and must block until the client responds.
testBlockAfterCloseSocket :: IO ()
testBlockAfterCloseSocket = do
    serverAddr <- newEmptyMVar
    clientAddr <- newEmptyMVar
    clientDone <- newEmptyMVar
    Right transport <- createTransport "127.0.0.1" "8085"
  
    forkTry $ server transport serverAddr clientAddr
    forkTry $ client transport serverAddr clientAddr clientDone 
  
    takeMVar clientDone

  where
    server :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> MVar EndPointAddress -> IO ()
    server transport serverAddr clientAddr = do
      tlog "Server"
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (fromJust . decodeEndPointAddress . address $ endpoint)

      -- Wait for the client to connect and disconnect
      tlog "Waiting for ConnectionOpened"
      ConnectionOpened _ _ _ <- receive endpoint
      tlog "Waiting for ConnectionClosed"
      ConnectionClosed _ <- receive endpoint
 
      -- At this point the server will have sent a CloseSocket request to the
      -- client, and must block until the client responds
      tlog "Server waiting to connect to the client.."
      Right _ <- readMVar clientAddr >>= \addr -> connect endpoint addr ReliableOrdered
      
      tlog "Server waiting.."

    client :: Transport -> MVar (N.HostName, N.ServiceName, EndPointId) -> MVar EndPointAddress -> MVar () -> IO ()
    client transport serverAddr clientAddr clientDone = do
      tlog "Client"
      Right endpoint <- newEndPoint transport
      putMVar clientAddr (address endpoint)
      let EndPointAddress myAddress = address endpoint

      -- Connect to the server
      addr:_ <- N.getAddrInfo Nothing (Just "127.0.0.1") (Just "8084")
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr)

      tlog "Connecting to endpoint"
      (_, _, endPointIx) <- readMVar serverAddr
      sendMany sock (encodeInt32 endPointIx : prependLength [myAddress])

      -- Wait for acknowledgement
      ConnectionRequestAccepted <- toEnum <$> recvInt32 sock

      -- Request a new connection
      tlog "Requesting connection"
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
      response <- replicateM 4 $ recvInt32 sock :: IO [Int32] 

      -- Close the connection again
      tlog "Closing connection"
      sendMany sock [encodeInt32 CloseConnection, encodeInt32 (response !! 3)] 

      -- Server will now send a CloseSocket request as its refcount reached 0
      tlog "Waiting for CloseSocket request"
      CloseSocket <- toEnum <$> recvInt32 sock

      unblocked <- newEmptyMVar

      -- We should not hear from the server until we unblock him by
      -- responding to the CloseSocket request (in this case, we 
      -- respond by sending a ConnectionRequest)
      forkTry $ do
        recvInt32 sock :: IO Int32
        isEmptyMVar unblocked >>= (guard . not)
        putMVar clientDone ()

      threadDelay 1000000

      tlog "Client ignores close socket and sends connection request"
      tlog "This should unblock the server"
      putMVar unblocked ()
      let reqId' = 1 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId']

main :: IO ()
main = do
  tryIO $ runTests 
           [ ("EarlyDisconnect",       testEarlyDisconnect)
           , ("InvalidAddress",        testInvalidAddress)
           , ("InvalidConnect",        testInvalidConnect)
           , ("IgnoreCloseSocket",     testIgnoreCloseSocket)
           , ("BlockAfterCloseSocket", testBlockAfterCloseSocket)
           ]
  Right transport <- createTransport "127.0.0.1" "8080" 
  testTransport transport 
