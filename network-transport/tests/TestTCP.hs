{-# LANGUAGE RebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import Prelude hiding (catch, (>>=), (>>), return, fail)
import TestTransport (testTransport) 
import TestAuxiliary (forkTry, runTests)
import Network.Transport
import Network.Transport.TCP ( createTransport
                             , createTransportExposeInternals
                             , TransportInternals(..)
                             , encodeEndPointAddress
                             )
import Data.Int (Int32)
import Control.Concurrent (threadDelay, killThread)
import Control.Concurrent.MVar ( MVar
                               , newEmptyMVar
                               , putMVar
                               , takeMVar
                               , readMVar
                               , isEmptyMVar
                               , newMVar
                               , modifyMVar
                               )
import Control.Monad (replicateM, guard, forM_, replicateM_, when)
import Control.Applicative ((<$>))
import Control.Exception (throwIO, try, SomeException)
import Network.Transport.TCP ( ControlHeader(..)
                             , ConnectionRequestResponse(..)
                             , socketToEndPoint
                             )
import Network.Transport.Internal ( encodeInt32
                                  , prependLength
                                  , tlog
                                  , tryIO
                                  , void
                                  )
import Network.Transport.Internal.TCP (recvInt32, forkServer, recvWithLength)
import qualified Network.Socket as N ( sClose
                                     , ServiceName
                                     , Socket
                                     , AddrInfo
                                     , shutdown
                                     , ShutdownCmd(ShutdownSend)
                                     )
import Network.Socket.ByteString (sendMany)                                     
import Data.String (fromString)
import Traced 
import GHC.IO.Exception (ioe_errno)
import Foreign.C.Error (Errno(..), eADDRNOTAVAIL)
import System.Timeout (timeout)

instance Traceable ControlHeader where
  trace = traceShow

instance Traceable ConnectionRequestResponse where
  trace = traceShow

instance Traceable N.Socket where
  trace = traceShow 

instance Traceable N.AddrInfo where
  trace = traceShow

instance Traceable TransportInternals where
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
      Left (TransportError SendFailed _) <- send conn ["ping2"]

      -- *Pfew* 
      putMVar serverDone ()

    client :: MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"
      clientPort <- nextPort
      let  ourAddress = encodeEndPointAddress "127.0.0.1" clientPort 0 
      putMVar clientAddr ourAddress 
 
      -- Listen for incoming messages
      forkServer "127.0.0.1" clientPort 5 throwIO $ \sock -> do
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
      Left (TransportError SendFailed _) <- send conn ["ping2"]

      -- *Pfew* 
      putMVar serverDone ()

    client :: MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"
      clientPort <- nextPort
      let  ourAddress = encodeEndPointAddress "127.0.0.1" clientPort 0 
      putMVar clientAddr ourAddress 
 
      -- Listen for incoming messages
      forkServer "127.0.0.1" clientPort 5 throwIO $ \sock -> do
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
    -- We pick an address < 127.0.0.1 so that this is not rejected purely because of the "crossed" check 
    let ourAddress = EndPointAddress "126.0.0.1"
    Right (_, ConnectionRequestAccepted) <- readMVar serverAddr >>= socketToEndPoint ourAddress 
    Right (_, ConnectionRequestInvalid)  <- readMVar serverAddr >>= socketToEndPoint ourAddress 
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
        throwIO ex
      Right transport ->
        replicateM_ 3 $ do
          Right endpoint <- newEndPoint transport
          Right _        <- connect endpoint (address masterEndPoint) ReliableOrdered defaultConnectHints
          return ()

-- | Test what happens when the transport breaks completely
testBreakTransport :: IO N.ServiceName -> IO ()
testBreakTransport nextPort = do
  Right (transport, internals) <- nextPort >>= createTransportExposeInternals "127.0.0.1"
  Right endpoint <- newEndPoint transport

  killThread (transportThread internals) -- Uh oh

  ErrorEvent (TransportError EventTransportFailed _) <- receive endpoint 

  return ()

-- | Test that a second call to 'connect' might succeed even if the first
-- failed. This is a TCP specific test rather than an endpoint specific test
-- because we must manually create the endpoint address to match an endpoint we
-- have yet to set up.
-- Then test that we get a connection lost message after the remote endpoint
-- suddenly closes the socket, and that a subsequent 'connect' allows us to
-- re-establish a connection to the same endpoint
testReconnect :: IO N.ServiceName -> IO ()
testReconnect nextPort = do
  serverPort      <- nextPort
  serverDone      <- newEmptyMVar
  firstAttempt    <- newEmptyMVar
  endpointCreated <- newEmptyMVar

  -- Server
  forkTry $ do 
    -- Wait for the client to do its first attempt
    readMVar firstAttempt 

    counter <- newMVar (0 :: Int) 

    forkServer "127.0.0.1" serverPort 5 throwIO $ \sock -> do
      -- Accept the connection 
      Right 0  <- tryIO $ (recvInt32 sock :: IO Int)
      Right _  <- tryIO $ recvWithLength sock 
      Right () <- tryIO $ sendMany sock [encodeInt32 ConnectionRequestAccepted]

      -- The first time we close the socket before accepting the logical connection
      count <- modifyMVar counter $ \i -> return (i + 1, i)

      when (count > 0) $ do
        -- Client requests a logical connection
        Right RequestConnectionId <- tryIO $ toEnum <$> (recvInt32 sock :: IO Int)
        Right reqId <- tryIO $ (recvInt32 sock :: IO Int)
        Right () <- tryIO $ sendMany sock (encodeInt32 ControlResponse : encodeInt32 reqId : prependLength [encodeInt32 (10001 :: Int)])
        return ()

      when (count > 1) $ do
        -- Client sends a message
        Right 10001 <- tryIO $ (recvInt32 sock :: IO Int)
        Right ["ping"] <- tryIO $ recvWithLength sock
        putMVar serverDone ()
        
      Right () <- tryIO $ N.sClose sock
      return ()

    putMVar endpointCreated ()

  -- Client
  forkTry $ do
    Right transport <- nextPort >>= createTransport "127.0.0.1" 
    Right endpoint  <- newEndPoint transport
    let theirAddr = encodeEndPointAddress "127.0.0.1" serverPort 0

    -- The first attempt will fail because no endpoint is yet set up
    Left (TransportError ConnectNotFound _) <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    putMVar firstAttempt ()

    -- The second attempt will fail because the server closes the socket before we can request a connection
    takeMVar endpointCreated
    -- This might time out or not, depending on whether the server closes the
    -- socket before or after we can send the RequestConnectionId request 
    resultConnect <- timeout 500000 $ connect endpoint theirAddr ReliableOrdered defaultConnectHints 
    case resultConnect of
      Nothing -> return ()
      Just (Left (TransportError ConnectFailed _)) -> return ()
      _ -> fail "testReconnect"

    -- The third attempt succeeds
    Right conn1 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    
    -- But a send will fail because the server has closed the connection again
    Left (TransportError SendFailed _) <- send conn1 ["ping"]
    ErrorEvent (TransportError (EventConnectionLost _ []) _) <- receive endpoint

    -- But a subsequent call to connect should reestablish the connection
    Right conn2 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

    -- Send should now succeed
    Right () <- send conn2 ["ping"]
    return ()

  takeMVar serverDone

-- Test what happens if we close the socket one way only. This means that the
-- 'recv' in 'handleIncomingMessages' will not fail, but a 'send' or 'connect'
-- *will* fail. We are testing that error handling everywhere does the right
-- thing.
testUnidirectionalError :: IO N.ServiceName -> IO ()
testUnidirectionalError nextPort = do
  clientDone <- newEmptyMVar
  serverPort <- nextPort
  serverGotPing <- newEmptyMVar

  -- Server
  forkServer "127.0.0.1" serverPort 5 throwIO $ \sock -> do
    -- We accept connections, but when an exception occurs we don't do
    -- anything (in particular, we don't close the socket). This is important
    -- because when we shutdown one direction of the socket a recv here will
    -- fail, but we don't want to close that socket at that point (which
    -- would shutdown the socket in the other direction)
    void . (try :: IO () -> IO (Either SomeException ())) $ do
      0 <- recvInt32 sock :: IO Int
      _ <- recvWithLength sock
      () <- sendMany sock [encodeInt32 ConnectionRequestAccepted]

      RequestConnectionId <- toEnum <$> (recvInt32 sock :: IO Int)
      reqId <- recvInt32 sock :: IO Int
      sendMany sock (encodeInt32 ControlResponse : encodeInt32 reqId : prependLength [encodeInt32 (10001 :: Int)])
        
      10001    <- recvInt32 sock :: IO Int
      ["ping"] <- recvWithLength sock
      putMVar serverGotPing ()
    
  -- Client
  forkTry $ do
    Right (transport, internals) <- nextPort >>= createTransportExposeInternals "127.0.0.1"
    Right endpoint <- newEndPoint transport
    let theirAddr = encodeEndPointAddress "127.0.0.1" serverPort 0

    -- Establish a connection to the server
    Right conn1 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    send conn1 ["ping"]
    takeMVar serverGotPing

    -- Close the *outgoing* part of the socket only
    sock <- socketBetween internals (address endpoint) theirAddr 
    N.shutdown sock N.ShutdownSend

    -- At this point we cannot notice the problem yet so we shouldn't receive an event yet
    Nothing <- timeout 500000 $ receive endpoint
   
    -- But when we send we find the error
    Left (TransportError SendFailed _) <- send conn1 ["ping"]
    ErrorEvent (TransportError (EventConnectionLost _ []) _) <- receive endpoint

    -- A call to connect should now re-establish the connection
    Right conn2 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    send conn2 ["ping"]
    takeMVar serverGotPing

    -- Again, close the outgoing part of the socket
    sock' <- socketBetween internals (address endpoint) theirAddr 
    N.shutdown sock' N.ShutdownSend

    -- We now find the error when we attempt to close the connection
    Nothing <- timeout 500000 $ receive endpoint
    close conn2
    ErrorEvent (TransportError (EventConnectionLost _ []) _) <- receive endpoint
    Right conn3 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    send conn3 ["ping"]
    takeMVar serverGotPing

    -- We repeat once more. 
    sock'' <- socketBetween internals (address endpoint) theirAddr 
    N.shutdown sock'' N.ShutdownSend
   
    -- Now we notice the problem when we try to connect
    Nothing <- timeout 500000 $ receive endpoint
    Left (TransportError ConnectFailed _) <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    ErrorEvent (TransportError (EventConnectionLost _ []) _) <- receive endpoint
    Right conn4 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    send conn4 ["ping"]
    takeMVar serverGotPing

    putMVar clientDone  ()

  takeMVar clientDone

testInvalidCloseConnection :: IO N.ServiceName -> IO ()
testInvalidCloseConnection nextPort = do
  Right (transport, internals) <- nextPort >>= createTransportExposeInternals "127.0.0.1"
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  serverDone <- newEmptyMVar

  -- Server
  forkTry $ do
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    ConnectionOpened _ _ _ <- receive endpoint

    -- At this point the client sends an invalid request, so we terminate the
    -- connection
    ErrorEvent (TransportError (EventConnectionLost _ [_]) _) <- receive endpoint

    putMVar serverDone () 

  -- Client
  forkTry $ do
    Right endpoint <- newEndPoint transport
    let ourAddr = address endpoint

    -- Connect so that we have a TCP connection
    theirAddr  <- readMVar serverAddr
    Right _ <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

    -- Get a handle on the TCP connection and manually send an invalid CloseConnection request
    sock <- socketBetween internals ourAddr theirAddr 
    sendMany sock [encodeInt32 CloseConnection, encodeInt32 (12345 :: Int)]

    putMVar clientDone ()

  mapM_ takeMVar [clientDone, serverDone]

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
           , ("UnidirectionalError",    testUnidirectionalError nextPort)
           , ("InvalidCloseConnection", testInvalidCloseConnection nextPort)
           ]
  testTransport (either (Left . show) (Right) <$> nextPort >>= createTransport "127.0.0.1")
