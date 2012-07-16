{-# LANGUAGE RebindableSyntax #-}
module TestTransport where

import Prelude hiding 
  ( (>>=)
  , return
  , fail
  , (>>)
#if ! MIN_VERSION_base(4,6,0)
  , catch
#endif
  )
import TestAuxiliary (forkTry, runTests, trySome, randomThreadDelay)
import Control.Concurrent (forkIO, killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar, readMVar, tryTakeMVar, modifyMVar_, newMVar)
import Control.Exception (evaluate, throw, throwIO, bracket)
import Control.Monad (replicateM, replicateM_, when, guard, forM_, unless)
import Control.Monad.Error ()
import Control.Applicative ((<$>))
import Network.Transport 
import Network.Transport.Internal (tlog, tryIO, timeoutMaybe)
import Network.Transport.Util (spawn)
import System.Random (randomIO)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, delete, findWithDefault, adjust, null, toList, map)
import Data.String (fromString)
import Data.List (permutations)
import Traced

-- | Server that echoes messages straight back to the origin endpoint.
echoServer :: EndPoint -> IO ()
echoServer endpoint = do
    go Map.empty
  where
    go :: Map ConnectionId Connection -> IO () 
    go cs = do
      event <- receive endpoint
      case event of
        ConnectionOpened cid rel addr -> do
          tlog $ "Opened new connection " ++ show cid
          Right conn <- connect endpoint addr rel defaultConnectHints
          go (Map.insert cid conn cs) 
        Received cid payload -> do
          send (Map.findWithDefault (error $ "Received: Invalid cid " ++ show cid) cid cs) payload 
          go cs
        ConnectionClosed cid -> do 
          tlog $ "Close connection " ++ show cid
          close (Map.findWithDefault (error $ "ConnectionClosed: Invalid cid " ++ show cid) cid cs)
          go (Map.delete cid cs) 
        ReceivedMulticast _ _ -> 
          -- Ignore
          go cs
        ErrorEvent _ ->
          putStrLn $ "Echo server received error event: " ++ show event
        EndPointClosed ->
          return ()

-- | Ping client used in a few tests
ping :: EndPoint -> EndPointAddress -> Int -> ByteString -> IO ()
ping endpoint server numPings msg = do
  -- Open connection to the server
  tlog "Connect to echo server"
  Right conn <- connect endpoint server ReliableOrdered defaultConnectHints

  -- Wait for the server to open reply connection
  tlog "Wait for ConnectionOpened message"
  ConnectionOpened cid _ _ <- receive endpoint

  -- Send pings and wait for reply
  tlog "Send ping and wait for reply"
  replicateM_ numPings $ do
      send conn [msg]
      Received cid' [reply] <- receive endpoint ; True <- return $ cid == cid' && reply == msg
      return ()

  -- Close the connection
  tlog "Close the connection"
  close conn

  -- Wait for the server to close its connection to us
  tlog "Wait for ConnectionClosed message"
  ConnectionClosed cid' <- receive endpoint ; True <- return $ cid == cid' 

  -- Done
  tlog "Ping client done"
    
-- | Basic ping test
testPingPong :: Transport -> Int -> IO () 
testPingPong transport numPings = do
  tlog "Starting ping pong test"
  server <- spawn transport echoServer
  result <- newEmptyMVar

  -- Client 
  forkTry $ do
    tlog "Ping client"
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "ping"
    putMVar result () 
  
  takeMVar result

-- | Test that endpoints don't get confused
testEndPoints :: Transport -> Int -> IO () 
testEndPoints transport numPings = do
  server <- spawn transport echoServer
  dones <- replicateM 2 newEmptyMVar

  forM_ (zip dones ['A'..]) $ \(done, name) -> forkTry $ do 
    let name' :: ByteString
        name' = pack [name]
    Right endpoint <- newEndPoint transport
    tlog $ "Ping client " ++ show name' ++ ": " ++ show (address endpoint)
    ping endpoint server numPings name' 
    putMVar done () 

  forM_ dones takeMVar

-- Test that connections don't get confused
testConnections :: Transport -> Int -> IO () 
testConnections transport numPings = do
  server <- spawn transport echoServer
  result <- newEmptyMVar
  
  -- Client
  forkTry $ do
    Right endpoint <- newEndPoint transport

    -- Open two connections to the server
    Right conn1 <- connect endpoint server ReliableOrdered defaultConnectHints
    ConnectionOpened serv1 _ _ <- receive endpoint
   
    Right conn2 <- connect endpoint server ReliableOrdered defaultConnectHints
    ConnectionOpened serv2 _ _ <- receive endpoint

    -- One thread to send "pingA" on the first connection
    forkTry $ replicateM_ numPings $ send conn1 ["pingA"]

    -- One thread to send "pingB" on the second connection
    forkTry $ replicateM_ numPings $ send conn2 ["pingB"]

    -- Verify server responses 
    let verifyResponse 0 = putMVar result () 
        verifyResponse n = do 
          event <- receive endpoint
          case event of
            Received cid [payload] -> do
              when (cid == serv1 && payload /= "pingA") $ error "Wrong message"
              when (cid == serv2 && payload /= "pingB") $ error "Wrong message"
              verifyResponse (n - 1) 
            _ -> 
              verifyResponse n 
    verifyResponse (2 * numPings)

  takeMVar result

-- | Test that closing one connection does not close the other
testCloseOneConnection :: Transport -> Int -> IO ()
testCloseOneConnection transport numPings = do
  server <- spawn transport echoServer
  result <- newEmptyMVar
  
  -- Client
  forkTry $ do
    Right endpoint <- newEndPoint transport

    -- Open two connections to the server
    Right conn1 <- connect endpoint server ReliableOrdered defaultConnectHints
    ConnectionOpened serv1 _ _ <- receive endpoint
   
    Right conn2 <- connect endpoint server ReliableOrdered defaultConnectHints
    ConnectionOpened serv2 _ _ <- receive endpoint

    -- One thread to send "pingA" on the first connection
    forkTry $ do
      replicateM_ numPings $ send conn1 ["pingA"]
      close conn1
      
    -- One thread to send "pingB" on the second connection
    forkTry $ replicateM_ (numPings * 2) $ send conn2 ["pingB"]

    -- Verify server responses 
    let verifyResponse 0 = putMVar result () 
        verifyResponse n = do 
          event <- receive endpoint
          case event of
            Received cid [payload] -> do
              when (cid == serv1 && payload /= "pingA") $ error "Wrong message"
              when (cid == serv2 && payload /= "pingB") $ error "Wrong message"
              verifyResponse (n - 1) 
            _ -> 
              verifyResponse n 
    verifyResponse (3 * numPings)

  takeMVar result

-- | Test that if A connects to B and B connects to A, B can still send to A after
-- A closes its connection to B (for instance, in the TCP transport, the socket pair
-- connecting A and B should not yet be closed).
testCloseOneDirection :: Transport -> Int -> IO ()
testCloseOneDirection transport numPings = do
  addrA <- newEmptyMVar
  addrB <- newEmptyMVar
  doneA <- newEmptyMVar
  doneB <- newEmptyMVar

  -- A
  forkTry $ do
    tlog "A" 
    Right endpoint <- newEndPoint transport
    tlog (show (address endpoint))
    putMVar addrA (address endpoint)

    -- Connect to B
    tlog "Connect to B"
    Right conn <- readMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints

    -- Wait for B to connect to us
    tlog "Wait for B" 
    ConnectionOpened cid _ _ <- receive endpoint

    -- Send pings to B
    tlog "Send pings to B"
    replicateM_ numPings $ send conn ["ping"] 

    -- Close our connection to B
    tlog "Close connection"
    close conn
   
    -- Wait for B's pongs
    tlog "Wait for pongs from B" 
    replicateM_ numPings $ do Received _ _ <- receive endpoint ; return ()

    -- Wait for B to close it's connection to us
    tlog "Wait for B to close connection"
    ConnectionClosed cid' <- receive endpoint
    guard (cid == cid') 

    -- Done
    tlog "Done"
    putMVar doneA ()

  -- B
  forkTry $ do
    tlog "B"
    Right endpoint <- newEndPoint transport
    tlog (show (address endpoint))
    putMVar addrB (address endpoint)

    -- Wait for A to connect
    tlog "Wait for A to connect"
    ConnectionOpened cid _ _ <- receive endpoint

    -- Connect to A
    tlog "Connect to A"
    Right conn <- readMVar addrA >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints

    -- Wait for A's pings
    tlog "Wait for pings from A"
    replicateM_ numPings $ do Received _ _ <- receive endpoint ; return ()

    -- Wait for A to close it's connection to us
    tlog "Wait for A to close connection"
    ConnectionClosed cid' <- receive endpoint
    guard (cid == cid') 

    -- Send pongs to A
    tlog "Send pongs to A"
    replicateM_ numPings $ send conn ["pong"]
   
    -- Close our connection to A
    tlog "Close connection to A"
    close conn

    -- Done
    tlog "Done"
    putMVar doneB ()

  mapM_ takeMVar [doneA, doneB]

-- | Collect events and order them by connection ID
collect :: EndPoint -> Maybe Int -> Maybe Int -> IO [(ConnectionId, [[ByteString]])]
collect endPoint maxEvents timeout = go maxEvents Map.empty Map.empty
  where
    -- TODO: for more serious use of this function we'd need to make these arguments strict
    go (Just 0) open closed = finish open closed 
    go n open closed = do
      mEvent <- tryIO . timeoutMaybe timeout (userError "timeout") $ receive endPoint 
      case mEvent of 
        Left _ -> finish open closed
        Right event -> do
          let n' = (\x -> x - 1) <$> n
          case event of
            ConnectionOpened cid _ _ ->
              go n' (Map.insert cid [] open) closed
            ConnectionClosed cid ->
              let list = Map.findWithDefault (error "Invalid ConnectionClosed") cid open in
              go n' (Map.delete cid open) (Map.insert cid list closed)
            Received cid msg ->
              go n' (Map.adjust (msg :) cid open) closed
            ReceivedMulticast _ _ ->
              fail "Unexpected multicast"
            ErrorEvent _ ->
              fail "Unexpected error"
            EndPointClosed ->
              fail "Unexpected endpoint closure"

    finish open closed = 
      if Map.null open 
        then return . Map.toList . Map.map reverse $ closed
        else fail $ "Open connections: " ++ show (map fst . Map.toList $ open)

-- | Open connection, close it, then reopen it
-- (In the TCP transport this means the socket will be closed, then reopened)
--
-- Note that B cannot expect to receive all of A's messages on the first connection
-- before receiving the messages on the second connection. What might (and sometimes
-- does) happen is that finishes sending all of its messages on the first connection
-- (in the TCP transport, the first socket pair) while B is behind on reading _from_
-- this connection (socket pair) -- the messages are "in transit" on the network 
-- (these tests are done on localhost, so there are in some OS buffer). Then when
-- A opens the second connection (socket pair) B will spawn a new thread for this
-- connection, and hence might start interleaving messages from the first and second
-- connection. 
-- 
-- This is correct behaviour, however: the transport API guarantees reliability and
-- ordering _per connection_, but not _across_ connections.
testCloseReopen :: Transport -> Int -> IO ()
testCloseReopen transport numPings = do
  addrB <- newEmptyMVar
  doneB <- newEmptyMVar

  let numRepeats = 2 :: Int 

  -- A
  forkTry $ do
    Right endpoint <- newEndPoint transport

    forM_ [1 .. numRepeats] $ \i -> do
      tlog "A connecting"
      -- Connect to B
      Right conn <- readMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints
  
      tlog "A pinging"
      -- Say hi
      forM_ [1 .. numPings] $ \j -> send conn [pack $ "ping" ++ show i ++ "/" ++ show j]

      tlog "A closing"
      -- Disconnect again
      close conn

    tlog "A finishing"

  -- B
  forkTry $ do
    Right endpoint <- newEndPoint transport
    putMVar addrB (address endpoint)

    eventss <- collect endpoint (Just (numRepeats * (numPings + 2))) Nothing

    forM_ (zip [1 .. numRepeats] eventss) $ \(i, (_, events)) -> do
      forM_ (zip [1 .. numPings] events) $ \(j, event) -> do
        guard (event == [pack $ "ping" ++ show i ++ "/" ++ show j])

    putMVar doneB ()

  takeMVar doneB

-- | Test lots of parallel connection attempts
testParallelConnects :: Transport -> Int -> IO ()
testParallelConnects transport numPings = do
  server <- spawn transport echoServer
  done   <- newEmptyMVar 

  Right endpoint <- newEndPoint transport

  -- Spawn lots of clients
  forM_ [1 .. numPings] $ \i -> forkTry $ do 
    Right conn <- connect endpoint server ReliableOrdered defaultConnectHints
    send conn [pack $ "ping" ++ show i]
    send conn [pack $ "ping" ++ show i]
    close conn

  forkTry $ do
    eventss <- collect endpoint (Just (numPings * 4)) Nothing
    -- Check that no pings got sent to the wrong connection
    forM_ eventss $ \(_, [[ping1], [ping2]]) -> 
      guard (ping1 == ping2)
    putMVar done ()

  takeMVar done

-- | Test that sending on a closed connection gives an error
testSendAfterClose :: Transport -> Int -> IO ()
testSendAfterClose transport numRepeats = do
  server <- spawn transport echoServer
  clientDone <- newEmptyMVar

  forkTry $ do
    Right endpoint <- newEndPoint transport

    -- We request two lightweight connections
    replicateM numRepeats $ do
      Right conn1 <- connect endpoint server ReliableOrdered defaultConnectHints
      Right conn2 <- connect endpoint server ReliableOrdered defaultConnectHints
  
      -- Close the second, but leave the first open; then output on the second
      -- connection (i.e., on a closed connection while there is still another
      -- connection open)
      close conn2
      Left (TransportError SendClosed _) <- send conn2 ["ping2"]
  
      -- Now close the first connection, and output on it (i.e., output while
      -- there are no lightweight connection at all anymore)
      close conn1
      Left (TransportError SendClosed _) <- send conn2 ["ping2"]

      return ()

    putMVar clientDone ()

  takeMVar clientDone

-- | Test that closing the same connection twice has no effect
testCloseTwice :: Transport -> Int -> IO ()
testCloseTwice transport numRepeats = do 
  server <- spawn transport echoServer
  clientDone <- newEmptyMVar

  forkTry $ do
    Right endpoint <- newEndPoint transport

    replicateM numRepeats $ do
      -- We request two lightweight connections
      Right conn1 <- connect endpoint server ReliableOrdered defaultConnectHints
      Right conn2 <- connect endpoint server ReliableOrdered defaultConnectHints
  
      -- Close the second one twice
      close conn2
      close conn2
  
      -- Then send a message on the first and close that twice too
      send conn1 ["ping"]
      close conn1

      -- Verify expected response from the echo server
      ConnectionOpened cid1 _ _ <- receive endpoint
      ConnectionOpened cid2 _ _ <- receive endpoint
      ConnectionClosed cid2'    <- receive endpoint ; True <- return $ cid2' == cid2
      Received cid1' ["ping"]   <- receive endpoint ; True <- return $ cid1' == cid1 
      ConnectionClosed cid1''   <- receive endpoint ; True <- return $ cid1'' == cid1
      
      return ()
  
    putMVar clientDone ()

  takeMVar clientDone

-- | Test that we can connect an endpoint to itself
testConnectToSelf :: Transport -> Int -> IO ()
testConnectToSelf transport numPings = do
  done <- newEmptyMVar
  Right endpoint <- newEndPoint transport

  tlog "Creating self-connection"
  Right conn <- connect endpoint (address endpoint) ReliableOrdered defaultConnectHints

  tlog "Talk to myself"

  -- One thread to write to the endpoint
  forkTry $ do
    tlog $ "writing" 

    tlog $ "Sending ping"
    replicateM_ numPings $ send conn ["ping"]

    tlog $ "Closing connection"
    close conn

  -- And one thread to read
  forkTry $ do
    tlog $ "reading"

    tlog "Waiting for ConnectionOpened"
    ConnectionOpened cid _ addr <- receive endpoint ; True <- return $ addr == address endpoint

    tlog "Waiting for Received"
    replicateM_ numPings $ do
       Received cid' ["ping"] <- receive endpoint ; True <- return $ cid == cid'
       return ()

    tlog "Waiting for ConnectionClosed"
    ConnectionClosed cid' <- receive endpoint ; True <- return $ cid == cid'

    tlog "Done"
    putMVar done ()

  takeMVar done

-- | Test that we can connect an endpoint to itself multiple times
testConnectToSelfTwice :: Transport -> Int -> IO ()
testConnectToSelfTwice transport numPings = do
  done <- newEmptyMVar
  Right endpoint <- newEndPoint transport

  tlog "Creating self-connection"
  Right conn1 <- connect endpoint (address endpoint) ReliableOrdered defaultConnectHints
  Right conn2 <- connect endpoint (address endpoint) ReliableOrdered defaultConnectHints

  tlog "Talk to myself"

  -- One thread to write to the endpoint using the first connection
  forkTry $ do
    tlog $ "writing" 

    tlog $ "Sending ping"
    replicateM_ numPings $ send conn1 ["pingA"]

    tlog $ "Closing connection"
    close conn1
  
  -- One thread to write to the endpoint using the second connection
  forkTry $ do
    tlog $ "writing" 

    tlog $ "Sending ping"
    replicateM_ numPings $ send conn2 ["pingB"]

    tlog $ "Closing connection"
    close conn2

  -- And one thread to read
  forkTry $ do
    tlog $ "reading"

    [(_, events1), (_, events2)] <- collect endpoint (Just (2 * (numPings + 2))) Nothing
    True <- return $ events1 == replicate numPings ["pingA"]
    True <- return $ events2 == replicate numPings ["pingB"]

    tlog "Done"
    putMVar done ()

  takeMVar done

-- | Test that we self-connections no longer work once we close our endpoint
-- or our transport
testCloseSelf :: IO (Either String Transport) -> IO ()
testCloseSelf newTransport = do
  Right transport <- newTransport
  Right endpoint1 <- newEndPoint transport
  Right endpoint2 <- newEndPoint transport
  Right conn1     <- connect endpoint1 (address endpoint1) ReliableOrdered defaultConnectHints
  Right conn2     <- connect endpoint1 (address endpoint1) ReliableOrdered defaultConnectHints
  Right conn3     <- connect endpoint2 (address endpoint2) ReliableOrdered defaultConnectHints
 
  -- Close the conneciton and try to send
  close conn1
  Left (TransportError SendClosed _) <- send conn1 ["ping"]
  
  -- Close the first endpoint. We should not be able to use the first
  -- connection anymore, or open more self connections, but the self connection
  -- to the second endpoint should still be fine
  closeEndPoint endpoint1
  Left (TransportError SendFailed _) <- send conn2 ["ping"]
  Left (TransportError ConnectFailed _) <- connect endpoint1 (address endpoint1) ReliableOrdered defaultConnectHints
  Right () <- send conn3 ["ping"]

  -- Close the transport; now the second should no longer work
  closeTransport transport
  Left (TransportError SendFailed _) <- send conn3 ["ping"]
  Left (TransportError ConnectFailed _) <- connect endpoint2 (address endpoint2) ReliableOrdered defaultConnectHints

  return ()

-- | Test various aspects of 'closeEndPoint' 
testCloseEndPoint :: Transport -> Int -> IO ()
testCloseEndPoint transport _ = do
  serverDone <- newEmptyMVar
  clientDone <- newEmptyMVar
  clientAddr1 <- newEmptyMVar
  clientAddr2 <- newEmptyMVar
  serverAddr <- newEmptyMVar

  -- Server
  forkTry $ do
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    -- First test (see client)
    do
      theirAddr <- readMVar clientAddr1
      ConnectionOpened cid ReliableOrdered addr <- receive endpoint ; True <- return $ addr == theirAddr
      ConnectionClosed cid' <- receive endpoint ; True <- return $ cid == cid'
      return ()

    -- Second test
    do
      theirAddr <- readMVar clientAddr2
      
      ConnectionOpened cid ReliableOrdered addr <- receive endpoint ; True <- return $ addr == theirAddr
      Received cid' ["ping"] <- receive endpoint ; True <- return $ cid == cid'

      Right conn <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
      send conn ["pong"]

      ConnectionClosed cid'' <- receive endpoint ; True <- return $ cid == cid''
      ErrorEvent (TransportError (EventConnectionLost (Just addr') []) _) <- receive endpoint ; True <- return $ addr' == theirAddr

      Left (TransportError SendFailed _) <- send conn ["pong2"]
    
      return ()

    putMVar serverDone ()

  -- Client
  forkTry $ do
    theirAddr <- readMVar serverAddr

    -- First test: close endpoint with one outgoing but no incoming connections
    do
      Right endpoint <- newEndPoint transport
      putMVar clientAddr1 (address endpoint) 

      -- Connect to the server, then close the endpoint without disconnecting explicitly
      Right _ <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
      closeEndPoint endpoint
      EndPointClosed <- receive endpoint
      return ()

    -- Second test: close endpoint with one outgoing and one incoming connection
    do
      Right endpoint <- newEndPoint transport
      putMVar clientAddr2 (address endpoint) 

      Right conn <- connect endpoint theirAddr ReliableOrdered defaultConnectHints
      send conn ["ping"]

      -- Reply from the server
      ConnectionOpened cid ReliableOrdered addr <- receive endpoint ; True <- return $ addr == theirAddr
      Received cid' ["pong"] <- receive endpoint ; True <- return $ cid == cid'

      -- Close the endpoint 
      closeEndPoint endpoint
      EndPointClosed <- receive endpoint

      -- Attempt to send should fail with connection closed
      Left (TransportError SendFailed _) <- send conn ["ping2"]

      -- An attempt to close the already closed connection should just return
      () <- close conn

      -- And so should an attempt to connect
      Left (TransportError ConnectFailed _) <- connect endpoint theirAddr ReliableOrdered defaultConnectHints

      return ()

    putMVar clientDone ()

  mapM_ takeMVar [serverDone, clientDone]

-- Test closeTransport
--
-- This tests many of the same things that testEndPoint does, and some more
testCloseTransport :: IO (Either String Transport) -> IO ()
testCloseTransport newTransport = do
  serverDone <- newEmptyMVar
  clientDone <- newEmptyMVar
  clientAddr1 <- newEmptyMVar
  clientAddr2 <- newEmptyMVar
  serverAddr <- newEmptyMVar

  -- Server
  forkTry $ do
    Right transport <- newTransport
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    -- Client sets up first endpoint 
    theirAddr1 <- readMVar clientAddr1
    ConnectionOpened cid1 ReliableOrdered addr <- receive endpoint ; True <- return $ addr == theirAddr1

    -- Client sets up second endpoint 
    theirAddr2 <- readMVar clientAddr2
      
    ConnectionOpened cid2 ReliableOrdered addr' <- receive endpoint ; True <- return $ addr' == theirAddr2
    Received cid2' ["ping"] <- receive endpoint ; True <- return $ cid2' == cid2

    Right conn <- connect endpoint theirAddr2 ReliableOrdered defaultConnectHints
    send conn ["pong"]

    -- Client now closes down its transport. We should receive connection closed messages (we don't know the precise order, however)
    evs <- replicateM 3 $ receive endpoint
    let expected = [ ConnectionClosed cid1
                   , ConnectionClosed cid2
                   , ErrorEvent (TransportError (EventConnectionLost (Just theirAddr2) []) "")
                   ]
    True <- return $ any (== expected) (permutations evs)

    -- An attempt to send to the endpoint should now fail
    Left (TransportError SendFailed _) <- send conn ["pong2"]
    
    putMVar serverDone ()

  -- Client
  forkTry $ do
    Right transport <- newTransport
    theirAddr <- readMVar serverAddr

    -- Set up endpoint with one outgoing but no incoming connections
    Right endpoint1 <- newEndPoint transport
    putMVar clientAddr1 (address endpoint1) 

    -- Connect to the server, then close the endpoint without disconnecting explicitly
    Right _ <- connect endpoint1 theirAddr ReliableOrdered defaultConnectHints

    -- Set up an endpoint with one outgoing and out incoming connection
    Right endpoint2 <- newEndPoint transport
    putMVar clientAddr2 (address endpoint2) 

    Right conn <- connect endpoint2 theirAddr ReliableOrdered defaultConnectHints
    send conn ["ping"]

    -- Reply from the server
    ConnectionOpened cid ReliableOrdered addr <- receive endpoint2 ; True <- return $ addr == theirAddr
    Received cid' ["pong"] <- receive endpoint2 ; True <- return $ cid == cid'

    -- Now shut down the entire transport
    closeTransport transport

    -- Both endpoints should report that they have been closed
    EndPointClosed <- receive endpoint1
    EndPointClosed <- receive endpoint2

    -- Attempt to send should fail with connection closed
    Left (TransportError SendFailed _) <- send conn ["ping2"]

    -- An attempt to close the already closed connection should just return
    () <- close conn

    -- And so should an attempt to connect on either endpoint
    Left (TransportError ConnectFailed _) <- connect endpoint1 theirAddr ReliableOrdered defaultConnectHints
    Left (TransportError ConnectFailed _) <- connect endpoint2 theirAddr ReliableOrdered defaultConnectHints

    -- And finally, so should an attempt to create a new endpoint
    Left (TransportError NewEndPointFailed _) <- newEndPoint transport 

    putMVar clientDone ()

  mapM_ takeMVar [serverDone, clientDone]

-- | Remote node attempts to connect to a closed local endpoint
testConnectClosedEndPoint :: Transport -> IO ()
testConnectClosedEndPoint transport = do
  serverAddr   <- newEmptyMVar
  serverClosed <- newEmptyMVar
  clientDone   <- newEmptyMVar
  
  -- Server
  forkTry $ do
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)

    closeEndPoint endpoint
    putMVar serverClosed ()

  -- Client
  forkTry $ do
    Right endpoint <- newEndPoint transport
    readMVar serverClosed 

    Left (TransportError ConnectNotFound _) <- readMVar serverAddr >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints

    putMVar clientDone ()
  
  takeMVar clientDone

-- | We should receive an exception when doing a 'receive' after we have been
-- notified that an endpoint has been closed
testExceptionOnReceive :: IO (Either String Transport) -> IO ()
testExceptionOnReceive newTransport = do
  Right transport <- newTransport
  
  -- Test one: when we close an endpoint specifically
  Right endpoint1 <- newEndPoint transport
  closeEndPoint endpoint1
  EndPointClosed <- receive endpoint1
  Left _ <- trySome (receive endpoint1 >>= evaluate)

  -- Test two: when we close the entire transport
  Right endpoint2 <- newEndPoint transport
  closeTransport transport
  EndPointClosed <- receive endpoint2
  Left _ <- trySome (receive endpoint2 >>= evaluate)

  return ()

-- | Test what happens when the argument to 'send' is an exceptional value
testSendException :: IO (Either String Transport) -> IO ()
testSendException newTransport = do
  Right transport <- newTransport
  Right endpoint1 <- newEndPoint transport
  Right endpoint2 <- newEndPoint transport
  
  -- Connect endpoint1 to endpoint2
  Right conn <- connect endpoint1 (address endpoint2) ReliableOrdered defaultConnectHints
  ConnectionOpened _ _ _ <- receive endpoint2

  -- Send an exceptional value
  Left (TransportError SendFailed _) <- send conn (throw $ userError "uhoh")

  -- This will have been as a failure to send by endpoint1, which will
  -- therefore have closed the socket. In turn this will have caused endpoint2
  -- to report that the connection was lost 
  ErrorEvent (TransportError (EventConnectionLost _ []) _)  <- receive endpoint1
  ErrorEvent (TransportError (EventConnectionLost _ [_]) _) <- receive endpoint2

  -- A new connection will re-establish the connection
  Right conn2 <- connect endpoint1 (address endpoint2) ReliableOrdered defaultConnectHints
  send conn2 ["ping"]
  close conn2

  ConnectionOpened _ _ _ <- receive endpoint2
  Received _ ["ping"]    <- receive endpoint2
  ConnectionClosed _     <- receive endpoint2

  return ()

-- | If threads get killed while executing a 'connect', 'send', or 'close', this
-- should not affect other threads.
-- 
-- The intention of this test is to see what happens when a asynchronous
-- exception happes _while executing a send_. This is exceedingly difficult to
-- guarantee, however. Hence we run a large number of tests and insert random
-- thread delays -- and even then it might not happen.  Moreover, it will only
-- happen when we run on multiple cores. 
testKill :: IO (Either String Transport) -> Int -> IO ()
testKill newTransport numThreads = do
  Right transport1 <- newTransport
  Right transport2 <- newTransport
  Right endpoint1 <- newEndPoint transport1
  Right endpoint2 <- newEndPoint transport2
      
  threads <- replicateM numThreads . forkIO $ do 
    randomThreadDelay 100 
    bracket (connect endpoint1 (address endpoint2) ReliableOrdered defaultConnectHints)
            -- Note that we should not insert a randomThreadDelay into the 
            -- exception handler itself as this means that the exception handler
            -- could be interrupted and we might not close
            (\(Right conn) -> close conn)
            (\(Right conn) -> do randomThreadDelay 100 
                                 Right () <- send conn ["ping"]
                                 randomThreadDelay 100)

  numAlive <- newMVar (0 :: Int)

  -- Kill half of those threads
  forkIO . forM_ threads $ \tid -> do
    shouldKill <- randomIO
    if shouldKill
      then randomThreadDelay 600 >> killThread tid 
      else modifyMVar_ numAlive (return . (+ 1))

  -- Since it is impossible to predict when the kill exactly happens, we don't
  -- know how many connects were opened and how many pings were sent. But we
  -- should not have any open connections (if we do, collect will throw an
  -- error) and we should have at least the number of pings equal to the number
  -- of threads we did *not* kill 
  eventss <- collect endpoint2 Nothing (Just 1000000)   
  let actualPings = sum . map (length . snd) $ eventss
  expectedPings <- takeMVar numAlive
  unless (actualPings >= expectedPings) $ 
    throwIO (userError "Missing pings")
  
--  print (actualPings, expectedPings)


-- | Set up conditions with a high likelyhood of "crossing" (for transports
-- that multiplex lightweight connections across heavyweight connections)
testCrossing :: Transport -> Int -> IO () 
testCrossing transport numRepeats = do
  [aAddr, bAddr] <- replicateM 2 newEmptyMVar
  [aDone, bDone] <- replicateM 2 newEmptyMVar
  [aTimeout, bTimeout] <- replicateM 2 newEmptyMVar
  go <- newEmptyMVar

  let hints = defaultConnectHints {
                connectTimeout = Just 5000000
              }

  -- A
  forkTry $ do
    Right endpoint <- newEndPoint transport
    putMVar aAddr (address endpoint)
    theirAddress <- readMVar bAddr

    replicateM_ numRepeats $ do
      takeMVar go >> yield
      -- Because we are creating lots of connections, it's possible that
      -- connect times out (for instance, in the TCP transport,
      -- Network.Socket.connect may time out). We shouldn't regard this as an
      -- error in the Transport, though. 
      connectResult <- connect endpoint theirAddress ReliableOrdered hints
      case connectResult of
        Right conn -> close conn 
        Left (TransportError ConnectTimeout _) -> putMVar aTimeout ()
        Left (TransportError ConnectFailed _) -> readMVar bTimeout
        Left err -> throwIO . userError $ "testCrossed: " ++ show err
      putMVar aDone ()

  -- B
  forkTry $ do
    Right endpoint <- newEndPoint transport
    putMVar bAddr (address endpoint)
    theirAddress <- readMVar aAddr
    
    replicateM_ numRepeats $ do
      takeMVar go >> yield
      connectResult <- connect endpoint theirAddress ReliableOrdered hints
      case connectResult of
        Right conn -> close conn 
        Left (TransportError ConnectTimeout _) -> putMVar bTimeout () 
        Left (TransportError ConnectFailed _) -> readMVar aTimeout
        Left err -> throwIO . userError $ "testCrossed: " ++ show err
      putMVar bDone ()
  
  -- Driver
  forM_ [1 .. numRepeats] $ \_i -> do
    -- putStrLn $ "Round " ++ show _i
    tryTakeMVar aTimeout
    tryTakeMVar bTimeout
    putMVar go ()
    putMVar go ()
    takeMVar aDone
    takeMVar bDone

-- Transport tests
testTransport :: IO (Either String Transport) -> IO ()
testTransport newTransport = do
  Right transport <- newTransport
  runTests
    [ ("PingPong",              testPingPong transport numPings)
    , ("EndPoints",             testEndPoints transport numPings)
    , ("Connections",           testConnections transport numPings)
    , ("CloseOneConnection",    testCloseOneConnection transport numPings)
    , ("CloseOneDirection",     testCloseOneDirection transport numPings)
    , ("CloseReopen",           testCloseReopen transport numPings)
    , ("ParallelConnects",      testParallelConnects transport numPings)
    , ("SendAfterClose",        testSendAfterClose transport 100)
    , ("Crossing",              testCrossing transport 10)
    , ("CloseTwice",            testCloseTwice transport 100)
    , ("ConnectToSelf",         testConnectToSelf transport numPings) 
    , ("ConnectToSelfTwice",    testConnectToSelfTwice transport numPings)
    , ("CloseSelf",             testCloseSelf newTransport)
    , ("CloseEndPoint",         testCloseEndPoint transport numPings) 
    , ("CloseTransport",        testCloseTransport newTransport)
    , ("ConnectClosedEndPoint", testConnectClosedEndPoint transport)
    , ("ExceptionOnReceive",    testExceptionOnReceive newTransport)
    , ("SendException",         testSendException newTransport) 
    , ("Kill",                  testKill newTransport 1000)
    ]
  where
    numPings = 10000 :: Int
