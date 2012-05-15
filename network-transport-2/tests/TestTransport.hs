{-# LANGUAGE RebindableSyntax #-}
module TestTransport where

import Prelude hiding (catch, (>>=), (>>), return, fail)
import TestAuxiliary (forkTry, runTests)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar, readMVar)
import Control.Monad (replicateM, replicateM_, when, guard, forM_)
import Network.Transport
import Network.Transport.Internal (tlog)
import Network.Transport.Util (spawn)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, delete, findWithDefault, adjust, null, toList, map)
import Data.String (fromString)
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
          tlog $ "Opened new conncetion " ++ show cid
          Right conn <- connect endpoint addr rel 
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
          fail (show event)

-- | Ping client used in a few tests
ping :: EndPoint -> EndPointAddress -> Int -> ByteString -> IO ()
ping endpoint server numPings msg = do
  -- Open connection to the server
  tlog "Connect to echo server"
  Right conn <- connect endpoint server ReliableOrdered

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
    Right conn1 <- connect endpoint server ReliableOrdered
    ConnectionOpened serv1 _ _ <- receive endpoint
   
    Right conn2 <- connect endpoint server ReliableOrdered
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
    Right conn1 <- connect endpoint server ReliableOrdered
    ConnectionOpened serv1 _ _ <- receive endpoint
   
    Right conn2 <- connect endpoint server ReliableOrdered
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
    Right conn <- readMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered 

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
    Right conn <- readMVar addrA >>= \addr -> connect endpoint addr ReliableOrdered 

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

-- | Collect a given number of events and order them by connection ID
collect :: EndPoint -> Int -> IO [(ConnectionId, [[ByteString]])]
collect endPoint numEvents = go numEvents Map.empty Map.empty
  where
    -- TODO: for more serious use of this function we'd need to make these arguments strict
    go 0 open closed = if Map.null open 
                         then return . Map.toList . Map.map reverse $ closed
                         else fail "Open connections"
    go n open closed = do
      event <- receive endPoint 
      case event of
        ConnectionOpened cid _ _ ->
          go (n - 1) (Map.insert cid [] open) closed
        ConnectionClosed cid ->
          let list = Map.findWithDefault (error "Invalid ConnectionClosed") cid open in
          go (n - 1) (Map.delete cid open) (Map.insert cid list closed)
        Received cid msg ->
          go (n - 1) (Map.adjust (msg :) cid open) closed
        ReceivedMulticast _ _ ->
          fail "Unexpected multicast"
        ErrorEvent _ ->
          fail "Unexpected error"

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
      Right conn <- readMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered
  
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

    eventss <- collect endpoint (numRepeats * (numPings + 2))

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
    Right conn <- connect endpoint server ReliableOrdered
    send conn [pack $ "ping" ++ show i]
    send conn [pack $ "ping" ++ show i]
    close conn

  forkTry $ do
    eventss <- collect endpoint (numPings * 4)
    -- Check that no pings got sent to the wrong connection
    forM_ eventss $ \(_, [[ping1], [ping2]]) -> 
      guard (ping1 == ping2)
    putMVar done ()

  takeMVar done

-- | Test that sending on a closed connection gives an error
testSendAfterClose :: Transport -> Int -> IO ()
testSendAfterClose transport _ = do
  server <- spawn transport echoServer
  clientDone <- newEmptyMVar

  forkTry $ do
    Right endpoint <- newEndPoint transport

    -- We request two lightweight connections
    Right conn1 <- connect endpoint server ReliableOrdered
    Right conn2 <- connect endpoint server ReliableOrdered

    -- Close the second, but leave the first open; then output on the second
    -- connection (i.e., on a closed connection while there is still another
    -- connection open)
    close conn2
    Left (FailedWith SendConnectionClosed _) <- send conn2 ["ping2"]

    -- Now close the first connection, and output on it (i.e., output while
    -- there are no lightweight connection at all anymore)
    close conn1
    Left (FailedWith SendConnectionClosed _) <- send conn2 ["ping2"]

    putMVar clientDone ()

  takeMVar clientDone

-- | Test that closing the same connection twice has no effect
testCloseTwice :: Transport -> Int -> IO ()
testCloseTwice transport _ = do 
  server <- spawn transport echoServer
  clientDone <- newEmptyMVar

  forkTry $ do
    Right endpoint <- newEndPoint transport

    -- We request two lightweight connections
    Right conn1 <- connect endpoint server ReliableOrdered
    Right conn2 <- connect endpoint server ReliableOrdered

    -- Close the second one twice
    close conn2
    close conn2

    -- Then send a message on the first and close that too
    send conn1 ["ping"]
    close conn1

    -- Verify expected response from the echo server
    ConnectionOpened cid1 _ _ <- receive endpoint
    ConnectionOpened cid2 _ _ <- receive endpoint
    ConnectionClosed cid2'    <- receive endpoint ; True <- return $ cid2' == cid2
    Received cid1' ["ping"]   <- receive endpoint ; True <- return $ cid1' == cid1 
    ConnectionClosed cid1''   <- receive endpoint ; True <- return $ cid1'' == cid1

    putMVar clientDone ()

  takeMVar clientDone

-- | Test that we can connect an endpoint to itself
testConnectToSelf :: Transport -> Int -> IO ()
testConnectToSelf transport numPings = do
  done <- newEmptyMVar
  Right endpoint <- newEndPoint transport

  tlog "Creating self-connection"
  Right conn <- connect endpoint (address endpoint) ReliableOrdered

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
  Right conn1 <- connect endpoint (address endpoint) ReliableOrdered
  Right conn2 <- connect endpoint (address endpoint) ReliableOrdered

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

    [(_, events1), (_, events2)] <- collect endpoint (2 * (numPings + 2))
    True <- return $ events1 == replicate numPings ["pingA"]
    True <- return $ events2 == replicate numPings ["pingB"]

    tlog "Done"
    putMVar done ()

  takeMVar done

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

      Right conn <- connect endpoint theirAddr ReliableOrdered
      send conn ["pong"]

      ConnectionClosed cid'' <- receive endpoint ; True <- return $ cid == cid''
      ErrorEvent (ErrorEventConnectionLost addr' []) <- receive endpoint ; True <- return $ addr' == theirAddr

      Left (FailedWith SendConnectionClosed _) <- send conn ["pong2"]
    
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
      Right _ <- connect endpoint theirAddr ReliableOrdered
      closeEndPoint endpoint
      ErrorEvent (ErrorEventEndPointClosed []) <- receive endpoint
      return ()

    -- Second test: close endpoint with one outgoing and one incoming connection
    do
      Right endpoint <- newEndPoint transport
      putMVar clientAddr2 (address endpoint) 

      Right conn <- connect endpoint theirAddr ReliableOrdered
      send conn ["ping"]

      -- Reply from the server
      ConnectionOpened cid ReliableOrdered addr <- receive endpoint ; True <- return $ addr == theirAddr
      Received cid' ["pong"] <- receive endpoint ; True <- return $ cid == cid'

      -- Close the endpoint 
      closeEndPoint endpoint
      ErrorEvent (ErrorEventEndPointClosed [cid'']) <- receive endpoint; True <- return $ cid == cid''

      -- Attempt to send should fail with connection closed
      Left (FailedWith SendConnectionClosed _) <- send conn ["ping2"]

      -- An attempt to close the already closed connection should just return
      () <- close conn

      -- And so should an attempt to connect
      Left (FailedWith ConnectFailed _) <- connect endpoint theirAddr ReliableOrdered

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

    Right conn <- connect endpoint theirAddr2 ReliableOrdered
    send conn ["pong"]

    -- Client now closes down its transport. We should receive connection closed messages
    -- TODO: this assumes a certain ordering on the messages we receive; that's not guaranteed
    ConnectionClosed cid2'' <- receive endpoint ; True <- return $ cid2'' == cid2
    ErrorEvent (ErrorEventConnectionLost addr'' []) <- receive endpoint ; True <- return $ addr'' == theirAddr2
    ConnectionClosed cid1' <- receive endpoint ; True <- return $ cid1' == cid1

    -- An attempt to send to the endpoint should now fail
    Left (FailedWith SendConnectionClosed _) <- send conn ["pong2"]
    
    putMVar serverDone ()

  -- Client
  forkTry $ do
    Right transport <- newTransport
    theirAddr <- readMVar serverAddr

    -- Set up endpoint with one outgoing but no incoming connections
    Right endpoint1 <- newEndPoint transport
    putMVar clientAddr1 (address endpoint1) 

    -- Connect to the server, then close the endpoint without disconnecting explicitly
    Right _ <- connect endpoint1 theirAddr ReliableOrdered

    -- Set up an endpoint with one outgoing and out incoming connection
    Right endpoint2 <- newEndPoint transport
    putMVar clientAddr2 (address endpoint2) 

    Right conn <- connect endpoint2 theirAddr ReliableOrdered
    send conn ["ping"]

    -- Reply from the server
    ConnectionOpened cid ReliableOrdered addr <- receive endpoint2 ; True <- return $ addr == theirAddr
    Received cid' ["pong"] <- receive endpoint2 ; True <- return $ cid == cid'

    -- Now shut down the entire transport
    closeTransport transport

    -- Both endpoints should report an error
    ErrorEvent (ErrorEventEndPointClosed []) <- receive endpoint1
    ErrorEvent (ErrorEventEndPointClosed [cid'']) <- receive endpoint2; True <- return $ cid == cid''

    -- Attempt to send should fail with connection closed
    Left (FailedWith SendConnectionClosed _) <- send conn ["ping2"]

    -- An attempt to close the already closed connection should just return
    () <- close conn

    -- And so should an attempt to connect on either endpoint
    Left (FailedWith ConnectFailed _) <- connect endpoint1 theirAddr ReliableOrdered
    Left (FailedWith ConnectFailed _) <- connect endpoint2 theirAddr ReliableOrdered

    -- And finally, so should an attempt to create a new endpoint
    Left (FailedWith NewEndPointTransportFailure _) <- newEndPoint transport 

    putMVar clientDone ()

  mapM_ takeMVar [serverDone, clientDone]
  
testMany :: IO (Either String Transport) -> IO ()
testMany newTransport = do
  Right masterTransport <- newTransport
  Right masterEndPoint  <- newEndPoint masterTransport 

  replicateM_ 20 $ do
    Right transport <- newTransport
    replicateM_ 2 $ do
      Right endpoint <- newEndPoint transport
      Right _        <- connect endpoint (address masterEndPoint) ReliableOrdered 
      return ()

-- Transport tests
testTransport :: IO (Either String Transport) -> IO ()
testTransport newTransport = do
  Right transport <- newTransport
  runTests
    [ ("Many",               testMany newTransport)
    , ("PingPong",           testPingPong transport numPings)
    , ("EndPoints",          testEndPoints transport numPings)
    , ("Connections",        testConnections transport numPings)
    , ("CloseOneConnection", testCloseOneConnection transport numPings)
    , ("CloseOneDirection",  testCloseOneDirection transport numPings)
    , ("CloseReopen",        testCloseReopen transport numPings)
    , ("ParallelConnects",   testParallelConnects transport numPings)
    , ("SendAfterClose",     testSendAfterClose transport numPings)
    , ("CloseTwice",         testCloseTwice transport numPings)
    , ("ConnectToSelf",      testConnectToSelf transport numPings) 
    , ("ConnectToSelfTwice", testConnectToSelfTwice transport numPings)
    , ("CloseEndPoint",      testCloseEndPoint transport numPings) 
    , ("CloseTransport",     testCloseTransport newTransport) 
    ]
  where
    numPings = 10000 :: Int
