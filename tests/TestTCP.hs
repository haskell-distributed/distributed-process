{-# LANGUAGE RebindableSyntax, TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import Prelude hiding
  ( (>>=)
  , return
  , fail
  , (>>)
#if ! MIN_VERSION_base(4,6,0)
  , catch
#endif
  )
import Network.Transport
import Network.Transport.TCP ( createTransport
                             , createTransportExposeInternals
                             , TransportInternals(..)
                             , encodeEndPointAddress
                             , defaultTCPParameters
                             , LightweightConnectionId
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
                               , modifyMVar_
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
import Network.Transport.TCP.Internal (recvInt32, forkServer, recvWithLength)

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket as N
#else
import qualified Network.Socket as N
#endif
  ( sClose
  , ServiceName
  , Socket
  , AddrInfo
  , shutdown
  , ShutdownCmd(ShutdownSend)
  )

#ifdef USE_MOCK_NETWORK
import Network.Transport.TCP.Mock.Socket.ByteString (sendMany)
#else
import Network.Socket.ByteString (sendMany)
#endif

import Data.String (fromString)
import GHC.IO.Exception (ioe_errno)
import Foreign.C.Error (Errno(..), eADDRNOTAVAIL)
import System.Timeout (timeout)
import Network.Transport.Tests (testTransport)
import Network.Transport.Tests.Auxiliary (forkTry, runTests)
import Network.Transport.Tests.Traced

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
    server :: MVar EndPointAddress -> MVar EndPointAddress -> MVar () -> IO ()
    server serverAddr clientAddr serverDone = do
      tlog "Server"
      Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters
      Right endpoint  <- newEndPoint transport
      putMVar serverAddr (address endpoint)
      theirAddr <- readMVar clientAddr

      -- TEST 1: they connect to us, then drop the connection
      do
        ConnectionOpened _ _ addr <- receive endpoint
        True <- return $ addr == theirAddr

        ErrorEvent (TransportError (EventConnectionLost addr') _) <- receive endpoint
        True <- return $ addr' == theirAddr

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

        ErrorEvent (TransportError (EventConnectionLost addr') _) <- receive endpoint
        True <- return $ addr' == theirAddr

        return ()

      -- TEST 4: A subsequent send on an already-open connection will now break
      Left (TransportError SendFailed _) <- send conn ["ping2"]

      -- *Pfew*
      putMVar serverDone ()

    client :: MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"

      -- Listen for incoming messages
      (clientPort, _) <- forkServer "127.0.0.1" "0" 5 True throwIO $ \sock -> do
        -- Initial setup
        0 <- recvInt32 sock :: IO Int
        _ <- recvWithLength sock
        sendMany sock [encodeInt32 ConnectionRequestAccepted]

        -- Server opens  a logical connection
        CreatedNewConnection <- toEnum <$> (recvInt32 sock :: IO Int)
        1024 <- recvInt32 sock :: IO LightweightConnectionId

        -- Server sends a message
        1024 <- recvInt32 sock :: IO Int
        ["ping"] <- recvWithLength sock

        -- Reply
        sendMany sock [encodeInt32 CreatedNewConnection, encodeInt32 (10002 :: Int)]
        sendMany sock (encodeInt32 10002 : prependLength ["pong"])

        -- Close the socket
        N.sClose sock

      let ourAddress = encodeEndPointAddress "127.0.0.1" clientPort 0
      putMVar clientAddr ourAddress

      -- Connect to the server
      Right (sock, ConnectionRequestAccepted) <- readMVar serverAddr >>= \addr -> socketToEndPoint ourAddress addr True False False Nothing Nothing

      -- Open a new connection
      sendMany sock [encodeInt32 CreatedNewConnection, encodeInt32 (10003 :: Int)]

      -- Close the socket without closing the connection explicitly
      -- The server should receive an error event
      N.sClose sock

-- | Test the behaviour of a premature CloseSocket request
testEarlyCloseSocket :: IO ()
testEarlyCloseSocket = do
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
      Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters
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

        ErrorEvent (TransportError (EventConnectionLost addr') _) <- receive endpoint
        True <- return $ addr' == theirAddr

        return ()

      -- TEST 4: A subsequent send on an already-open connection will now break
      Left (TransportError SendFailed _) <- send conn ["ping2"]

      -- *Pfew*
      putMVar serverDone ()

    client :: MVar EndPointAddress -> MVar EndPointAddress -> IO ()
    client serverAddr clientAddr = do
      tlog "Client"

      -- Listen for incoming messages
      (clientPort, _) <- forkServer "127.0.0.1" "0" 5 True throwIO $ \sock -> do
        -- Initial setup
        0 <- recvInt32 sock :: IO Int
        _ <- recvWithLength sock
        sendMany sock [encodeInt32 ConnectionRequestAccepted]

        -- Server opens a logical connection
        CreatedNewConnection <- toEnum <$> (recvInt32 sock :: IO Int)
        1024 <- recvInt32 sock :: IO LightweightConnectionId

        -- Server sends a message
        1024 <- recvInt32 sock :: IO Int
        ["ping"] <- recvWithLength sock

        -- Reply
        sendMany sock [encodeInt32 CreatedNewConnection, encodeInt32 (10002 :: Int)]
        sendMany sock (encodeInt32 (10002 :: Int) : prependLength ["pong"])

        -- Send a CloseSocket even though there are still connections *in both
        -- directions*
        sendMany sock [encodeInt32 CloseSocket, encodeInt32 (1024 :: Int)]
        N.sClose sock

      let ourAddress = encodeEndPointAddress "127.0.0.1" clientPort 0
      putMVar clientAddr ourAddress

      -- Connect to the server
      Right (sock, ConnectionRequestAccepted) <- readMVar serverAddr >>= \addr -> socketToEndPoint ourAddress addr True False False Nothing Nothing

      -- Open a new connection
      sendMany sock [encodeInt32 CreatedNewConnection, encodeInt32 (10003 :: Int)]

      -- Send a CloseSocket without sending a closeconnecton
      -- The server should still receive a ConnectionClosed message
      sendMany sock [encodeInt32 CloseSocket, encodeInt32 (0 :: Int)]
      N.sClose sock

-- | Test the creation of a transport with an invalid address
testInvalidAddress :: IO ()
testInvalidAddress = do
  Left _ <- createTransport "invalidHostName" "0" defaultTCPParameters
  return ()

-- | Test connecting to invalid or non-existing endpoints
testInvalidConnect :: IO ()
testInvalidConnect = do
  Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters
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
    connect endpoint (encodeEndPointAddress "127.0.0.1" "0" 1) ReliableOrdered defaultConnectHints

  return ()

-- | Test that an endpoint can ignore CloseSocket requests (in "reality" this
-- would happen when the endpoint sends a new connection request before
-- receiving an (already underway) CloseSocket request)
testIgnoreCloseSocket :: IO ()
testIgnoreCloseSocket = do
  serverAddr <- newEmptyMVar
  clientAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  serverDone <- newEmptyMVar
  connectionEstablished <- newEmptyMVar
  Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters

  -- Server
  forkTry $ do
    tlog "Server"
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    let ourAddress = address endpoint
    theirAddress <- readMVar clientAddr

    -- Wait for the client to set up the TCP connection to us
    takeMVar connectionEstablished

    -- Connect then disconnect to the client
    Right conn <- connect endpoint theirAddress ReliableOrdered defaultConnectHints
    close conn

    -- At this point the server will have sent a CloseSocket request to the
    -- client, which however ignores it, instead it requests and closes
    -- another connection
    tlog "Waiting for ConnectionOpened"
    ConnectionOpened _ _ _ <- receive endpoint
    tlog "Waiting for ConnectionClosed"
    ConnectionClosed _ <- receive endpoint

    putMVar serverDone ()

  -- Client
  forkTry $ do
    tlog "Client"
    Right endpoint <- newEndPoint transport
    putMVar clientAddr (address endpoint)

    let ourAddress = address endpoint
    theirAddress <- readMVar serverAddr

    -- Connect to the server
    Right (sock, ConnectionRequestAccepted) <- socketToEndPoint ourAddress theirAddress True False False Nothing Nothing
    putMVar connectionEstablished ()

    -- Server connects to us, and then closes the connection
    CreatedNewConnection <- toEnum <$> (recvInt32 sock :: IO Int)
    1024 <- recvInt32 sock :: IO LightweightConnectionId

    CloseConnection <-  toEnum <$> (recvInt32 sock :: IO Int)
    1024 <- recvInt32 sock :: IO LightweightConnectionId

    -- Server will now send a CloseSocket request as its refcount reached 0
    tlog "Waiting for CloseSocket request"
    CloseSocket <- toEnum <$> recvInt32 sock
    _ <- recvInt32 sock :: IO LightweightConnectionId

    -- But we ignore it and request another connection in the other direction
    tlog "Ignoring it, requesting another connection"
    sendMany sock [encodeInt32 CreatedNewConnection, encodeInt32 (1024 :: Int)]

    -- Close it again
    tlog "Closing connection"
    sendMany sock [encodeInt32 CloseConnection, encodeInt32 (1024 :: Int)]

    -- And close the connection completely
    tlog "Closing socket"
    sendMany sock [encodeInt32 CloseSocket, encodeInt32 (1024 :: Int)]
    N.sClose sock

    putMVar clientDone ()

  takeMVar clientDone
  takeMVar serverDone

-- | Like 'testIgnoreSocket', but now the server requests a connection after the
-- client closed their connection. In the meantime, the server will have sent a
-- CloseSocket request to the client, and must block until the client responds.
testBlockAfterCloseSocket :: IO ()
testBlockAfterCloseSocket = do
  serverAddr <- newEmptyMVar
  clientAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  serverDone <- newEmptyMVar
  connectionEstablished <- newEmptyMVar
  Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters

  -- Server
  forkTry $ do
    tlog "Server"
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    let ourAddress = address endpoint
    theirAddress <- readMVar clientAddr

    -- Wait for the client to set up the TCP connection to us
    takeMVar connectionEstablished

    -- Connect then disconnect to the client
    Right conn <- connect endpoint theirAddress ReliableOrdered defaultConnectHints
    close conn

    -- At this point the server will have sent a CloseSocket request to the
    -- client, and must block until the client responds
    Right conn <- connect endpoint theirAddress ReliableOrdered defaultConnectHints

    putMVar serverDone ()

  -- Client
  forkTry $ do
    tlog "Client"
    Right endpoint <- newEndPoint transport
    putMVar clientAddr (address endpoint)

    let ourAddress = address endpoint
    theirAddress <- readMVar serverAddr

    -- Connect to the server
    Right (sock, ConnectionRequestAccepted) <- socketToEndPoint ourAddress theirAddress True False False Nothing Nothing
    putMVar connectionEstablished ()

    -- Server connects to us, and then closes the connection
    CreatedNewConnection <- toEnum <$> (recvInt32 sock :: IO Int)
    1024 <- recvInt32 sock :: IO LightweightConnectionId

    CloseConnection <-  toEnum <$> (recvInt32 sock :: IO Int)
    1024 <- recvInt32 sock :: IO LightweightConnectionId

    -- Server will now send a CloseSocket request as its refcount reached 0
    tlog "Waiting for CloseSocket request"
    CloseSocket <- toEnum <$> recvInt32 sock
    _ <- recvInt32 sock :: IO LightweightConnectionId

    unblocked <- newMVar False

    -- We should not hear from the server until we unblock him by
    -- responding to the CloseSocket request (in this case, we
    -- respond by sending a ConnectionRequest)
    forkTry $ do
      recvInt32 sock :: IO Int32
      readMVar unblocked >>= guard
      putMVar clientDone ()

    threadDelay 1000000

    tlog "Client ignores close socket and sends connection request"
    tlog "This should unblock the server"
    modifyMVar_ unblocked $ \_ -> return True
    sendMany sock [encodeInt32 CreatedNewConnection, encodeInt32 (1024 :: Int)]

  takeMVar clientDone
  takeMVar serverDone

-- | Test what happens when a remote endpoint sends a connection request to our
-- transport for an endpoint it already has a connection to
testUnnecessaryConnect :: Int -> IO ()
testUnnecessaryConnect numThreads = do
  clientDone <- newEmptyMVar
  serverAddr <- newEmptyMVar

  forkTry $ do
    Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

  forkTry $ do
    -- We pick an address < 127.0.0.1 so that this is not rejected purely because of the "crossed" check
    let ourAddress = EndPointAddress "126.0.0.1"

    -- We should only get a single 'Accepted' reply
    gotAccepted <- newEmptyMVar
    dones <- replicateM numThreads $ do
      done <- newEmptyMVar
      forkTry $ do
        -- It is possible that the remote endpoint just rejects the request by closing the socket
        -- immediately (depending on far the remote endpoint got with the initialization)
        response <- readMVar serverAddr >>= \addr -> socketToEndPoint ourAddress addr True False False Nothing Nothing
        case response of
          Right (_, ConnectionRequestAccepted) ->
            -- We don't close this socket because we want to keep this connection open
            putMVar gotAccepted ()
          -- We might get either Invalid or Crossed (the transport does not
          -- maintain enough history to be able to tell)
          Right (sock, ConnectionRequestInvalid) ->
            N.sClose sock
          Right (sock, ConnectionRequestCrossed) ->
            N.sClose sock
          Left _ ->
            return ()
        putMVar done ()
      return done

    mapM_ readMVar (gotAccepted : dones)
    putMVar clientDone ()

  takeMVar clientDone

-- | Test that we can create "many" transport instances
testMany :: IO ()
testMany = do
  Right masterTransport <- createTransport "127.0.0.1" "0" defaultTCPParameters
  Right masterEndPoint  <- newEndPoint masterTransport

  replicateM_ 10 $ do
    mTransport <- createTransport "127.0.0.1" "0" defaultTCPParameters
    case mTransport of
      Left ex -> do
        putStrLn $ "IOException: " ++ show ex ++ "; errno = " ++ show (ioe_errno ex)
        case (ioe_errno ex) of
          Just no | Errno no == eADDRNOTAVAIL -> putStrLn "(ADDRNOTAVAIL)"
          _ -> return ()
        throwIO ex
      Right transport ->
        replicateM_ 2 $ do
          Right endpoint <- newEndPoint transport
          Right _        <- connect endpoint (address masterEndPoint) ReliableOrdered defaultConnectHints
          return ()

-- | Test what happens when the transport breaks completely
testBreakTransport :: IO ()
testBreakTransport = do
  Right (transport, internals) <- createTransportExposeInternals "127.0.0.1" "0" defaultTCPParameters
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
testReconnect :: IO ()
testReconnect = do
  serverDone      <- newEmptyMVar
  endpointCreated <- newEmptyMVar

  counter <- newMVar (0 :: Int)

  -- Server
  (serverPort, _) <- forkServer "127.0.0.1" "0" 5 True throwIO $ \sock -> do
    -- Accept the connection
    Right 0  <- tryIO $ (recvInt32 sock :: IO Int)
    Right _  <- tryIO $ recvWithLength sock

    -- The first time we close the socket before accepting the logical connection
    count <- modifyMVar counter $ \i -> return (i + 1, i)

    when (count > 0) $ do
      Right () <- tryIO $ sendMany sock [encodeInt32 ConnectionRequestAccepted]
      -- Client requests a logical connection
      when (count > 1) $ do
        Right CreatedNewConnection <- tryIO $ toEnum <$> (recvInt32 sock :: IO Int)
        connId <- recvInt32 sock :: IO LightweightConnectionId
        return ()

        when (count > 2) $ do
          -- Client sends a message
          Right connId' <- tryIO $ (recvInt32 sock :: IO LightweightConnectionId)
          True <- return $ connId == connId'
          Right ["ping"] <- tryIO $ recvWithLength sock
          putMVar serverDone ()

    Right () <- tryIO $ N.sClose sock
    return ()

  putMVar endpointCreated ()

  -- Client
  forkTry $ do
    Right transport <- createTransport "127.0.0.1" "0" defaultTCPParameters
    Right endpoint  <- newEndPoint transport
    let theirAddr = encodeEndPointAddress "127.0.0.1" serverPort 0

    -- The second attempt will fail because the server closes the socket before we can request a connection
    takeMVar endpointCreated
    -- This might time out or not, depending on whether the server closes the
    -- socket before or after we can send the RequestConnectionId request
    resultConnect <- timeout 500000 $ connect endpoint theirAddr ReliableOrdered defaultConnectHints
    case resultConnect of
      Nothing -> return ()
      Just (Left (TransportError ConnectFailed _)) -> return ()
      Just (Left err) -> throwIO err
      Just (Right _) -> throwIO $ userError "testConnect: unexpected connect success"

    resultConnect <- timeout 500000 $ connect endpoint theirAddr ReliableOrdered defaultConnectHints
    case resultConnect of
      Nothing -> return ()
      Just (Left (TransportError ConnectFailed _)) -> return ()
      Just (Left err) -> throwIO err
      Just (Right c) -> do
        ev <- send c ["foo"]
        case ev of
          Left _ -> return ()
          Right _ -> throwIO $ userError "testConnect: unexpected send success"

    -- The third attempt succeeds
    Right conn1 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

    -- But a send will fail because the server has closed the connection again
    threadDelay 100000
    Left (TransportError SendFailed _) <- send conn1 ["ping"]
    ErrorEvent (TransportError (EventConnectionLost _) _) <- receive endpoint

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
testUnidirectionalError :: IO ()
testUnidirectionalError = do
  clientDone <- newEmptyMVar
  serverGotPing <- newEmptyMVar

  -- Server
  (serverPort, _) <- forkServer "127.0.0.1" "0" 5 True throwIO $ \sock -> do
    -- We accept connections, but when an exception occurs we don't do
    -- anything (in particular, we don't close the socket). This is important
    -- because when we shutdown one direction of the socket a recv here will
    -- fail, but we don't want to close that socket at that point (which
    -- would shutdown the socket in the other direction)
    void . (try :: IO () -> IO (Either SomeException ())) $ do
      0 <- recvInt32 sock :: IO Int
      _ <- recvWithLength sock
      () <- sendMany sock [encodeInt32 ConnectionRequestAccepted]

      CreatedNewConnection <- toEnum <$> (recvInt32 sock :: IO Int)
      connId <- recvInt32 sock :: IO LightweightConnectionId

      connId' <- recvInt32 sock :: IO LightweightConnectionId
      True <- return $ connId == connId'
      ["ping"] <- recvWithLength sock
      putMVar serverGotPing ()

  -- Client
  forkTry $ do
    Right (transport, internals) <- createTransportExposeInternals "127.0.0.1" "0" defaultTCPParameters
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
    ErrorEvent (TransportError (EventConnectionLost _) _) <- receive endpoint

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
    ErrorEvent (TransportError (EventConnectionLost _) _) <- receive endpoint
    Right conn3 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    send conn3 ["ping"]
    takeMVar serverGotPing

    -- We repeat once more.
    sock'' <- socketBetween internals (address endpoint) theirAddr
    N.shutdown sock'' N.ShutdownSend

    -- Now we notice the problem when we try to connect
    Nothing <- timeout 500000 $ receive endpoint
    Left (TransportError ConnectFailed _) <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    ErrorEvent (TransportError (EventConnectionLost _) _) <- receive endpoint
    Right conn4 <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
    send conn4 ["ping"]
    takeMVar serverGotPing

    putMVar clientDone  ()

  takeMVar clientDone

testInvalidCloseConnection :: IO ()
testInvalidCloseConnection = do
  Right (transport, internals) <- createTransportExposeInternals "127.0.0.1" "0" defaultTCPParameters
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
    ErrorEvent (TransportError (EventConnectionLost _) _) <- receive endpoint

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

testUseRandomPort :: IO ()
testUseRandomPort = do
   testDone <- newEmptyMVar
   forkTry $ do
     Right transport1 <- createTransport "127.0.0.1" "0" defaultTCPParameters
     Right ep1        <- newEndPoint transport1
     Right transport2 <- createTransport "127.0.0.1" "0" defaultTCPParameters
     Right ep2        <- newEndPoint transport2
     Right conn1 <- connect ep2 (address ep1) ReliableOrdered defaultConnectHints
     ConnectionOpened _ _ _ <- receive ep1
     putMVar testDone ()
   takeMVar testDone

main :: IO ()
main = do
  tcpResult <- tryIO $ runTests
           [ ("Use random port"       , testUseRandomPort)
           , ("EarlyDisconnect",        testEarlyDisconnect)
           , ("EarlyCloseSocket",       testEarlyCloseSocket)
           , ("IgnoreCloseSocket",      testIgnoreCloseSocket)
           , ("BlockAfterCloseSocket",  testBlockAfterCloseSocket)
           , ("UnnecessaryConnect",     testUnnecessaryConnect 10)
           , ("InvalidAddress",         testInvalidAddress)
           , ("InvalidConnect",         testInvalidConnect)
           , ("Many",                   testMany)
           , ("BreakTransport",         testBreakTransport)
           , ("Reconnect",              testReconnect)
           , ("UnidirectionalError",    testUnidirectionalError)
           , ("InvalidCloseConnection", testInvalidCloseConnection)
           ]
  -- Run the generic tests even if the TCP specific tests failed..
  testTransport (either (Left . show) (Right) <$>
    createTransport "127.0.0.1" "0" defaultTCPParameters)
  -- ..but if the generic tests pass, still fail if the specific tests did not
  case tcpResult of
    Left err -> throwIO err
    Right () -> return ()
