{-# LANGUAGE RebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import Prelude hiding (catch, (>>=), (>>), return, fail)
import TestTransport (testTransport) 
import TestAuxiliary (forkTry, runTests)
import Network.Transport
import Network.Transport.TCP (createTransport, createTransportExposeInternals, encodeEndPointAddress)
import Data.Int (Int32)
import Control.Concurrent (threadDelay, ThreadId, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, readMVar, isEmptyMVar)
import Control.Monad (replicateM, guard, forM_, replicateM_)
import Control.Applicative ((<$>))
import Control.Exception (throw)
import Network.Transport.TCP ( ControlHeader(..)
                             , ConnectionRequestResponse(..)
                             , socketToEndPoint
                             )
import Network.Transport.Internal (encodeInt32, prependLength, tlog, tryIO)
import Network.Transport.Internal.TCP (recvInt32, forkServer, recvWithLength)
import qualified Network.Socket as N ( sClose
                                     , ServiceName
                                     , Socket
                                     , AddrInfo
                                     )
import Network.Socket.ByteString (sendMany)                                     
import Data.String (fromString)
import Traced 
import GHC.IO.Exception (ioe_errno)
import Foreign.C.Error (Errno(..), eADDRNOTAVAIL)

instance Traceable ControlHeader where
  trace = traceShow

instance Traceable ConnectionRequestResponse where
  trace = traceShow

instance Traceable N.Socket where
  trace = const Nothing

instance Traceable N.AddrInfo where
  trace = traceShow

instance Traceable ThreadId where
  trace = const Nothing

-- Test that the server gets a ConnectionClosed message when the client closes
-- the socket without sending an explicit control message to the server first
testEarlyDisconnect :: IO N.ServiceName -> IO ()
testEarlyDisconnect nextPort = do
    clientAddr <- newEmptyMVar
    serverAddr <- newEmptyMVar
    serverDone <- newEmptyMVar

    tlog "testEarlyDisconnect"
    forkTry $ server serverAddr clientAddr serverDone
    forkTry $ client serverAddr clientAddr

    takeMVar serverDone
  where
    server :: MVar EndPointAddress -> MVar EndPointAddress -> MVar () -> IO ()
    server serverAddr clientAddr serverDone = do
      tlog "Server"
      Right transport <- nextPort >>= createTransport "127.0.0.1" 
      Right endpoint  <- newEndPoint transport
      putMVar serverAddr (address endpoint)
      theirAddr <- readMVar clientAddr

      -- TEST 1: they connect to us, then drop the connection
      do
        ConnectionOpened cid _ addr <- receive endpoint 
        True <- return $ addr == theirAddr
      
        ErrorEvent (TransportError (EventConnectionLost addr' [cid']) _) <- receive endpoint 
        True <- return $ addr' == theirAddr && cid' == cid

        return ()

      -- TEST 2: after they dropped their connection to us, we now try to
      -- establish a connection to them. This should re-establish the broken
      -- TCP connection. 
      tlog "Trying to connect to client"
      Right conn <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

      -- TEST 3: To test the connection, we do a simple ping test; as before,
      -- however, the remote client won't close the connection nicely but just
      -- closes the socket
      do
        Right () <- send conn ["ping"]
        
        ConnectionOpened cid _ addr <- receive endpoint 
        True <- return $ addr == theirAddr
        
        Received cid' ["pong"] <- receive endpoint
        True <- return $ cid == cid'
        
        ErrorEvent (TransportError (EventConnectionLost addr' [cid'']) _) <- receive endpoint
        True <- return $ addr' == theirAddr && cid'' == cid

        return ()

      -- TEST 4: A subsequent send on an already-open connection will now break
      Left (TransportError SendClosed _) <- send conn ["ping2"]

      -- *Pfew* 
      putMVar serverDone ()

    client :: MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"
      clientPort <- nextPort
      let  ourAddress = encodeEndPointAddress "127.0.0.1" clientPort 0 
      putMVar clientAddr ourAddress 
 
      -- Listen for incoming messages
      forkServer "127.0.0.1" clientPort 5 throw $ \sock -> do
        -- Initial setup 
        0 <- recvInt32 sock :: IO Int
        _ <- recvWithLength sock 
        sendMany sock [encodeInt32 ConnectionRequestAccepted]

        -- Server requests a logical connection 
        RequestConnectionId <- toEnum <$> (recvInt32 sock :: IO Int)
        reqId <- recvInt32 sock :: IO Int
        sendMany sock (encodeInt32 ControlResponse : encodeInt32 reqId : prependLength [encodeInt32 (10001 :: Int)])

        -- Server sends a message
        10001 <- recvInt32 sock :: IO Int
        ["ping"] <- recvWithLength sock

        -- Reply 
        sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 (10002 :: Int)]
        ControlResponse <- toEnum <$> (recvInt32 sock :: IO Int)
        10002 <- recvInt32 sock :: IO Int 
        [cid] <- recvWithLength sock
        sendMany sock (cid : prependLength ["pong"]) 

        -- Close the socket
        N.sClose sock
 
      -- Connect to the server
      Right (sock, ConnectionRequestAccepted) <- readMVar serverAddr >>= socketToEndPoint ourAddress 
  
      -- Request a new connection, but don't wait for the response
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
  
      -- Close the socket without closing the connection explicitly
      -- The server should receive an error event 
      N.sClose sock

-- | Test the behaviour of a premature CloseSocket request
testEarlyCloseSocket :: IO N.ServiceName -> IO ()
testEarlyCloseSocket nextPort = do
    clientAddr <- newEmptyMVar
    serverAddr <- newEmptyMVar
    serverDone <- newEmptyMVar

    tlog "testEarlyDisconnect"
    forkTry $ server serverAddr clientAddr serverDone
    forkTry $ client serverAddr clientAddr

    takeMVar serverDone
  where
    server :: MVar EndPointAddress -> MVar EndPointAddress -> MVar () -> IO ()
    server serverAddr clientAddr serverDone = do
      tlog "Server"
      Right transport <- nextPort >>= createTransport "127.0.0.1" 
      Right endpoint  <- newEndPoint transport
      putMVar serverAddr (address endpoint)
      theirAddr <- readMVar clientAddr

      -- TEST 1: they connect to us, then send a CloseSocket. Since we don't
      -- have any outgoing connections, this means we will agree to close the
      -- socket  
      do
        ConnectionOpened cid _ addr <- receive endpoint 
        True <- return $ addr == theirAddr
      
        ConnectionClosed cid' <- receive endpoint 
        True <- return $ cid' == cid

        return ()

      -- TEST 2: after they dropped their connection to us, we now try to
      -- establish a connection to them. This should re-establish the broken
      -- TCP connection. 
      tlog "Trying to connect to client"
      Right conn <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

      -- TEST 3: To test the connection, we do a simple ping test; as before,
      -- however, the remote client won't close the connection nicely but just
      -- sends a CloseSocket -- except that now we *do* have outgoing
      -- connections, so we won't agree and hence will receive an error when
      -- the socket gets closed
      do
        Right () <- send conn ["ping"]
        
        ConnectionOpened cid _ addr <- receive endpoint
        True <- return $ addr == theirAddr
        
        Received cid' ["pong"] <- receive endpoint
        True <- return $ cid' == cid
        
        ConnectionClosed cid'' <- receive endpoint
        True <- return $ cid'' == cid
        
        ErrorEvent (TransportError (EventConnectionLost addr' []) _) <- receive endpoint
        True <- return $ addr' == theirAddr 
        
        return ()

      -- TEST 4: A subsequent send on an already-open connection will now break
      Left (TransportError SendClosed _) <- send conn ["ping2"]

      -- *Pfew* 
      putMVar serverDone ()

    client :: MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"
      clientPort <- nextPort
      let  ourAddress = encodeEndPointAddress "127.0.0.1" clientPort 0 
      putMVar clientAddr ourAddress 
 
      -- Listen for incoming messages
      forkServer "127.0.0.1" clientPort 5 throw $ \sock -> do
        -- Initial setup 
        0 <- recvInt32 sock :: IO Int
        _ <- recvWithLength sock 
        sendMany sock [encodeInt32 ConnectionRequestAccepted]

        -- Server requests a logical connection 
        RequestConnectionId <- toEnum <$> (recvInt32 sock :: IO Int)
        reqId <- recvInt32 sock :: IO Int
        sendMany sock (encodeInt32 ControlResponse : encodeInt32 reqId : prependLength [encodeInt32 (10001 :: Int)])

        -- Server sends a message
        10001 <- recvInt32 sock :: IO Int
        ["ping"] <- recvWithLength sock

        -- Reply 
        sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 (10002 :: Int)]
        ControlResponse <- toEnum <$> (recvInt32 sock :: IO Int)
        10002 <- recvInt32 sock :: IO Int 
        [cid] <- recvWithLength sock
        sendMany sock (cid : prependLength ["pong"]) 

        -- Send a CloseSocket even though there are still connections *in both
        -- directions*
        sendMany sock [encodeInt32 CloseSocket]
        N.sClose sock
 
      -- Connect to the server
      Right (sock, ConnectionRequestAccepted) <- readMVar serverAddr >>= socketToEndPoint ourAddress 
  
      -- Request a new connection, but don't wait for the response
      let reqId = 0 :: Int32
      sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
  
      -- Send a CloseSocket without sending a closeconnecton 
      -- The server should still receive a ConnectionClosed message
      sendMany sock [encodeInt32 CloseSocket]
      N.sClose sock

-- | Test the creation of a transport with an invalid address
testInvalidAddress :: IO N.ServiceName -> IO ()
testInvalidAddress nextPort = do
  Left _ <- nextPort >>= createTransport "invalidHostName" 
  return ()

-- | Test connecting to invalid or non-existing endpoints
testInvalidConnect :: IO N.ServiceName -> IO ()
testInvalidConnect nextPort = do
  port            <- nextPort
  Right transport <- createTransport "127.0.0.1" port 
  Right endpoint  <- newEndPoint transport

  -- Syntax error in the endpoint address
  Left (TransportError ConnectFailed _) <- 
    connect endpoint (EndPointAddress "InvalidAddress") ReliableOrdered defaultConnectHints
 
  -- Syntax connect, but invalid hostname (TCP address lookup failure)
  Left (TransportError ConnectNotFound _) <- 
    connect endpoint (encodeEndPointAddress "invalidHost" "port" 0) ReliableOrdered defaultConnectHints
 
  -- TCP address correct, but nobody home at that address
  Left (TransportError ConnectNotFound _) <- 
    connect endpoint (encodeEndPointAddress "127.0.0.1" "9000" 0) ReliableOrdered defaultConnectHints
 
  -- Valid TCP address but invalid endpoint number
  Left (TransportError ConnectNotFound _) <- 
    connect endpoint (encodeEndPointAddress "127.0.0.1" port 1) ReliableOrdered defaultConnectHints

  return ()

-- | Test that an endpoint can ignore CloseSocket requests (in "reality" this
-- would happen when the endpoint sends a new connection request before
-- receiving an (already underway) CloseSocket request) 
testIgnoreCloseSocket :: IO N.ServiceName -> IO ()
testIgnoreCloseSocket nextPort = do
    serverAddr <- newEmptyMVar
    clientDone <- newEmptyMVar
    Right transport <- nextPort >>= createTransport "127.0.0.1" 
  
    forkTry $ server transport serverAddr
    forkTry $ client transport serverAddr clientDone 
  
    takeMVar clientDone

  where
    server :: Transport -> MVar EndPointAddress -> IO ()
    server transport serverAddr = do
      tlog "Server"
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (address endpoint)

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

    client :: Transport -> MVar EndPointAddress -> MVar () -> IO ()
    client transport serverAddr clientDone = do
      tlog "Client"
      Right endpoint <- newEndPoint transport
      let ourAddress = address endpoint

      -- Connect to the server
      Right (sock, ConnectionRequestAccepted) <- readMVar serverAddr >>= socketToEndPoint ourAddress  

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
testBlockAfterCloseSocket :: IO N.ServiceName -> IO ()
testBlockAfterCloseSocket nextPort = do
    serverAddr <- newEmptyMVar
    clientAddr <- newEmptyMVar
    clientDone <- newEmptyMVar
    port       <- nextPort 
    Right transport <- createTransport "127.0.0.1" port
  
    forkTry $ server transport serverAddr clientAddr
    forkTry $ client transport serverAddr clientAddr clientDone 
  
    takeMVar clientDone

  where
    server :: Transport -> MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    server transport serverAddr clientAddr = do
      tlog "Server"
      Right endpoint <- newEndPoint transport
      putMVar serverAddr (address endpoint)

      -- Wait for the client to connect and disconnect
      tlog "Waiting for ConnectionOpened"
      ConnectionOpened _ _ _ <- receive endpoint
      tlog "Waiting for ConnectionClosed"
      ConnectionClosed _ <- receive endpoint
 
      -- At this point the server will have sent a CloseSocket request to the
      -- client, and must block until the client responds
      tlog "Server waiting to connect to the client.."
      Right _ <- readMVar clientAddr >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints
      
      tlog "Server waiting.."

    client :: Transport -> MVar EndPointAddress -> MVar EndPointAddress -> MVar () -> IO ()
    client transport serverAddr clientAddr clientDone = do
      tlog "Client"
      Right endpoint <- newEndPoint transport
      putMVar clientAddr (address endpoint)
      let ourAddress = address endpoint

      -- Connect to the server
      Right (sock, ConnectionRequestAccepted) <- readMVar serverAddr >>= socketToEndPoint ourAddress 

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

-- | Test what happens when a remote endpoint sends a connection request to our
-- transport for an endpoint it already has a connection to
testUnnecessaryConnect :: IO N.ServiceName -> IO () 
testUnnecessaryConnect nextPort = do
  clientDone <- newEmptyMVar
  serverAddr <- newEmptyMVar

  forkTry $ do
    Right transport <- nextPort >>= createTransport "127.0.0.1"
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

  forkTry $ do
    let ourAddress = EndPointAddress "ourAddress"
    Right (_, ConnectionRequestAccepted) <- readMVar serverAddr >>= socketToEndPoint ourAddress 
    Right (_, ConnectionRequestCrossed)  <- readMVar serverAddr >>= socketToEndPoint ourAddress 
    putMVar clientDone ()

  takeMVar clientDone

-- | Test that we can create "many" transport instances
testMany :: IO N.ServiceName -> IO ()
testMany nextPort = do
  Right masterTransport <- nextPort >>= createTransport "127.0.0.1" 
  Right masterEndPoint  <- newEndPoint masterTransport 

  replicateM_ 20 $ do
    mTransport <- nextPort >>= createTransport "127.0.0.1" 
    case mTransport of
      Left ex -> do
        putStrLn $ "IOException: " ++ show ex ++ "; errno = " ++ show (ioe_errno ex)
        case (ioe_errno ex) of
          Just no | Errno no == eADDRNOTAVAIL -> putStrLn "(ADDRNOTAVAIL)" 
          _ -> return ()
        throw ex
      Right transport ->
        replicateM_ 3 $ do
          Right endpoint <- newEndPoint transport
          Right _        <- connect endpoint (address masterEndPoint) ReliableOrdered defaultConnectHints
          return ()

-- | Test what happens when the transport breaks completely
testBreakTransport :: IO N.ServiceName -> IO ()
testBreakTransport nextPort = do
  Right (transport, transportThread) <- nextPort >>= createTransportExposeInternals "127.0.0.1"
  Right endpoint <- newEndPoint transport

  killThread transportThread -- Uh oh

  ErrorEvent (TransportError EventTransportFailed _) <- receive endpoint 

  return ()

-- | Test that a second call to 'connect' might succeed even if the first
-- failed. This is a TCP specific test rather than an endpoint specific test
-- because we must manually create the endpoint address to match an endpoint we
-- have yet to set up
testReconnect :: IO N.ServiceName -> IO ()
testReconnect nextPort = do
  clientDone      <- newEmptyMVar
  firstAttempt    <- newEmptyMVar
  endpointCreated <- newEmptyMVar
  port            <- nextPort
  Right transport <- createTransport "127.0.0.1" port

  -- Server
  forkTry $ do 
    takeMVar firstAttempt
    newEndPoint transport
    putMVar endpointCreated ()

  -- Client
  forkTry $ do
    Right endpoint <- newEndPoint transport
    let theirAddr = encodeEndPointAddress "127.0.0.1" port 1

    Left (TransportError ConnectNotFound _) <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    putMVar firstAttempt ()

    takeMVar endpointCreated
    Right _ <-  connect endpoint theirAddr ReliableOrdered defaultConnectHints

    putMVar clientDone ()

  takeMVar clientDone



main :: IO ()
main = do
  portMVar <- newEmptyMVar
  forkTry $ forM_ ([10080 ..] :: [Int]) $ putMVar portMVar . show 
  let nextPort = takeMVar portMVar 
  tryIO $ runTests 
           [ ("EarlyDisconnect",        testEarlyDisconnect nextPort)
           , ("EarlyCloseSocket",       testEarlyCloseSocket nextPort)
           , ("IgnoreCloseSocket",      testIgnoreCloseSocket nextPort)
           , ("BlockAfterCloseSocket",  testBlockAfterCloseSocket nextPort)
           , ("TestUnnecessaryConnect", testUnnecessaryConnect nextPort)
           , ("InvalidAddress",         testInvalidAddress nextPort)
           , ("InvalidConnect",         testInvalidConnect nextPort) 
           , ("Many",                   testMany nextPort)
           , ("BreakTransport",         testBreakTransport nextPort)
           , ("Reconnect",              testReconnect nextPort)
           ]
  testTransport (either (Left . show) (Right) <$> nextPort >>= createTransport "127.0.0.1")
