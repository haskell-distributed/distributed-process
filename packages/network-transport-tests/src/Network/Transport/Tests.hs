{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE CPP  #-}
module Network.Transport.Tests where

import Prelude hiding
  ( (>>=)
  , return
  , fail
  , (>>)
  )
import Control.Concurrent (forkIO, killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar, readMVar, tryTakeMVar, modifyMVar_, newMVar)
import Control.Exception
  ( evaluate
  , throw
  , throwIO
  , bracket
  , catch
  , ErrorCall(..)
  )
import Control.Monad (replicateM, replicateM_, when, guard, forM_, unless)
import Control.Monad.Except ()
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
import Network.Transport.Tests.Auxiliary (forkTry, runTests, trySome, randomThreadDelay)
import Network.Transport.Tests.Expect
  ( expectConnectionClosed
  , expectConnectionOpened
  , expectEndPointClosed
  , expectEq
  , expectErrorEvent
  , expectLeft
  , expectReceived
  , expectRight
  , expectTransportError
  , expectTrue
  )
import Network.Transport.Tests.Traced

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
          conn <- expectRight "echoServer: connect" =<< connect endpoint addr rel defaultConnectHints
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
  conn <- expectRight "ping: connect" =<< connect endpoint server ReliableOrdered defaultConnectHints

  -- Wait for the server to open reply connection
  tlog "Wait for ConnectionOpened message"
  (cid, _, _) <- expectConnectionOpened =<< receive endpoint

  -- Send pings and wait for reply
  tlog "Send ping and wait for reply"
  replicateM_ numPings $ do
      send conn [msg]
      ev <- receive endpoint
      expectEq "ping: echoed event" (Received cid [msg]) ev

  -- Close the connection
  tlog "Close the connection"
  close conn

  -- Wait for the server to close its connection to us
  tlog "Wait for ConnectionClosed message"
  ev <- receive endpoint
  expectEq "ping: connection closed event" (ConnectionClosed cid) ev

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
    endpoint <- expectRight "testPingPong: newEndPoint" =<< newEndPoint transport
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
    endpoint <- expectRight "testEndPoints: newEndPoint" =<< newEndPoint transport
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
    endpoint <- expectRight "testConnections: newEndPoint" =<< newEndPoint transport

    -- Open two connections to the server
    conn1 <- expectRight "testConnections: connect (conn1)" =<< connect endpoint server ReliableOrdered defaultConnectHints
    (serv1, _, _) <- expectConnectionOpened =<< receive endpoint

    conn2 <- expectRight "testConnections: connect (conn2)" =<< connect endpoint server ReliableOrdered defaultConnectHints
    (serv2, _, _) <- expectConnectionOpened =<< receive endpoint

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
    endpoint <- expectRight "testCloseOneConnection: newEndPoint" =<< newEndPoint transport

    -- Open two connections to the server
    conn1 <- expectRight "testCloseOneConnection: connect (conn1)" =<< connect endpoint server ReliableOrdered defaultConnectHints
    (serv1, _, _) <- expectConnectionOpened =<< receive endpoint

    conn2 <- expectRight "testCloseOneConnection: connect (conn2)" =<< connect endpoint server ReliableOrdered defaultConnectHints
    (serv2, _, _) <- expectConnectionOpened =<< receive endpoint

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
    endpoint <- expectRight "testCloseOneDirection (A): newEndPoint" =<< newEndPoint transport
    tlog (show (address endpoint))
    putMVar addrA (address endpoint)

    -- Connect to B
    tlog "Connect to B"
    conn <- expectRight "testCloseOneDirection (A): connect to B"
              =<< (readMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints)

    -- Wait for B to connect to us
    tlog "Wait for B"
    (cid, _, _) <- expectConnectionOpened =<< receive endpoint

    -- Send pings to B
    tlog "Send pings to B"
    replicateM_ numPings $ send conn ["ping"]

    -- Close our connection to B
    tlog "Close connection"
    close conn

    -- Wait for B's pongs
    tlog "Wait for pongs from B"
    replicateM_ numPings $ do
      _ <- expectReceived =<< receive endpoint
      return ()

    -- Wait for B to close it's connection to us
    tlog "Wait for B to close connection"
    cid' <- expectConnectionClosed =<< receive endpoint
    expectEq "testCloseOneDirection (A): closed connection id" cid cid'

    -- Done
    tlog "Done"
    putMVar doneA ()

  -- B
  forkTry $ do
    tlog "B"
    endpoint <- expectRight "testCloseOneDirection (B): newEndPoint" =<< newEndPoint transport
    tlog (show (address endpoint))
    putMVar addrB (address endpoint)

    -- Wait for A to connect
    tlog "Wait for A to connect"
    (cid, _, _) <- expectConnectionOpened =<< receive endpoint

    -- Connect to A
    tlog "Connect to A"
    conn <- expectRight "testCloseOneDirection (B): connect to A"
              =<< (readMVar addrA >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints)

    -- Wait for A's pings
    tlog "Wait for pings from A"
    replicateM_ numPings $ do
      _ <- expectReceived =<< receive endpoint
      return ()

    -- Wait for A to close it's connection to us
    tlog "Wait for A to close connection"
    cid' <- expectConnectionClosed =<< receive endpoint
    expectEq "testCloseOneDirection (B): closed connection id" cid cid'

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
    endpoint <- expectRight "testCloseReopen (A): newEndPoint" =<< newEndPoint transport

    forM_ [1 .. numRepeats] $ \i -> do
      tlog "A connecting"
      -- Connect to B
      conn <- expectRight "testCloseReopen (A): connect"
                =<< (readMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints)

      tlog "A pinging"
      -- Say hi
      forM_ [1 .. numPings] $ \j -> send conn [pack $ "ping" ++ show i ++ "/" ++ show j]

      tlog "A closing"
      -- Disconnect again
      close conn

    tlog "A finishing"

  -- B
  forkTry $ do
    endpoint <- expectRight "testCloseReopen (B): newEndPoint" =<< newEndPoint transport
    putMVar addrB (address endpoint)

    eventss <- collect endpoint (Just (numRepeats * (numPings + 2))) Nothing

    forM_ (zip [1 .. numRepeats] eventss) $ \(i, (_, events)) -> do
      forM_ (zip [1 .. numPings] events) $ \(j, event) -> do
        expectEq ("testCloseReopen (B): ping " ++ show i ++ "/" ++ show j)
                 [pack $ "ping" ++ show i ++ "/" ++ show j]
                 event

    putMVar doneB ()

  takeMVar doneB

-- | Test lots of parallel connection attempts
testParallelConnects :: Transport -> Int -> IO ()
testParallelConnects transport numPings = do
  server <- spawn transport echoServer
  done   <- newEmptyMVar

  endpoint <- expectRight "testParallelConnects: newEndPoint" =<< newEndPoint transport

  -- Spawn lots of clients
  forM_ [1 .. numPings] $ \i -> forkTry $ do
    conn <- expectRight "testParallelConnects: connect" =<< connect endpoint server ReliableOrdered defaultConnectHints
    send conn [pack $ "ping" ++ show i]
    send conn [pack $ "ping" ++ show i]
    close conn

  forkTry $ do
    eventss <- collect endpoint (Just (numPings * 4)) Nothing
    -- Check that no pings got sent to the wrong connection
    forM_ eventss $ \(_, events) -> case events of
      [[ping1], [ping2]] -> expectEq "testParallelConnects: both pings on same connection match" ping1 ping2
      _ -> ioError $ userError $
        "testParallelConnects: expected two single-fragment messages per connection, got " ++ show events
    putMVar done ()

  takeMVar done

-- | Test that sending an error to self gives an error in the sender
testSelfSend :: Transport -> IO ()
testSelfSend transport = do
    endpoint <- expectRight "testSelfSend: newEndPoint" =<< newEndPoint transport

    conn <- expectRight "testSelfSend: connect"
              =<< connect endpoint (address endpoint) ReliableOrdered defaultConnectHints

    -- Must clear the ConnectionOpened event or else sending may block
    _ <- expectConnectionOpened =<< receive endpoint

    do send conn [ error "bang!" ]
       error "testSelfSend: send didn't fail"
     `catch` (\(ErrorCall "bang!") -> return ())

    close conn

    -- Must clear this event or else closing the end point may block.
    _ <- expectConnectionClosed =<< receive endpoint

    closeEndPoint endpoint

-- | Test that sending on a closed connection gives an error
testSendAfterClose :: Transport -> Int -> IO ()
testSendAfterClose transport numRepeats = do
  server <- spawn transport echoServer
  clientDone <- newEmptyMVar

  forkTry $ do
    endpoint <- expectRight "testSendAfterClose: newEndPoint" =<< newEndPoint transport

    -- We request two lightweight connections
    replicateM numRepeats $ do
      conn1 <- expectRight "testSendAfterClose: connect (conn1)" =<< connect endpoint server ReliableOrdered defaultConnectHints
      conn2 <- expectRight "testSendAfterClose: connect (conn2)" =<< connect endpoint server ReliableOrdered defaultConnectHints

      -- Close the second, but leave the first open; then output on the second
      -- connection (i.e., on a closed connection while there is still another
      -- connection open)
      close conn2
      send conn2 ["ping2"] >>= expectTransportError "testSendAfterClose: send on closed conn2 (first)" SendClosed

      -- Now close the first connection, and output on it (i.e., output while
      -- there are no lightweight connection at all anymore)
      close conn1
      send conn2 ["ping2"] >>= expectTransportError "testSendAfterClose: send on closed conn2 (second)" SendClosed

      return ()

    putMVar clientDone ()

  takeMVar clientDone

-- | Test that closing the same connection twice has no effect
testCloseTwice :: Transport -> Int -> IO ()
testCloseTwice transport numRepeats = do
  server <- spawn transport echoServer
  clientDone <- newEmptyMVar

  forkTry $ do
    endpoint <- expectRight "testCloseTwice: newEndPoint" =<< newEndPoint transport

    replicateM numRepeats $ do
      -- We request two lightweight connections
      conn1 <- expectRight "testCloseTwice: connect (conn1)" =<< connect endpoint server ReliableOrdered defaultConnectHints
      conn2 <- expectRight "testCloseTwice: connect (conn2)" =<< connect endpoint server ReliableOrdered defaultConnectHints

      -- Close the second one twice
      close conn2
      close conn2

      -- Then send a message on the first and close that twice too
      send conn1 ["ping"]
      close conn1

      -- Verify expected response from the echo server
      (cid1, _, _) <- expectConnectionOpened =<< receive endpoint
      (cid2, _, _) <- expectConnectionOpened =<< receive endpoint
      -- ordering of the following messages may differ depending of
      -- implementation
      ms   <- replicateM 3 $ receive endpoint
      expectTrue ("testCloseTwice: event interleaving " ++ show ms) $
        testStreams ms [ [ ConnectionClosed cid2 ]
                       , [ Received cid1 ["ping"]
                         , ConnectionClosed cid1 ]
                       ]

    putMVar clientDone ()

  takeMVar clientDone

-- | Test that we can connect an endpoint to itself
testConnectToSelf :: Transport -> Int -> IO ()
testConnectToSelf transport numPings = do
  done <- newEmptyMVar
  reconnect <- newEmptyMVar
  endpoint <- expectRight "testConnectToSelf: newEndPoint" =<< newEndPoint transport

  tlog "Creating self-connection"
  conn <- expectRight "testConnectToSelf: connect (writer)"
            =<< connect endpoint (address endpoint) ReliableOrdered defaultConnectHints

  tlog "Talk to myself"

  -- One thread to write to the endpoint
  forkTry $ do
    tlog $ "writing"

    tlog $ "Sending ping"
    replicateM_ numPings $ send conn ["ping"]

    tlog $ "Closing connection"
    close conn
    readMVar reconnect
    (cid', _, _) <- expectConnectionOpened =<< receive endpoint
    evClose <- receive endpoint
    expectEq "testConnectToSelf (writer): ConnectionClosed for self-reconnect" (ConnectionClosed cid') evClose

  -- And one thread to read
  forkTry $ do
    tlog $ "reading"

    tlog "Waiting for ConnectionOpened"
    (cid, _, addr) <- expectConnectionOpened =<< receive endpoint

    tlog "Waiting for Received"
    replicateM_ numPings $ do
      ev <- receive endpoint
      expectEq "testConnectToSelf (reader): ping echo" (Received cid ["ping"]) ev

    tlog "Waiting for ConnectionClosed"
    ev <- receive endpoint
    expectEq "testConnectToSelf (reader): ConnectionClosed" (ConnectionClosed cid) ev

    putMVar reconnect ()

    -- Check that the addr supplied also connects to self.
    -- The other thread verifies this.
    conn' <- expectRight "testConnectToSelf: connect via returned addr"
               =<< connect endpoint addr ReliableOrdered defaultConnectHints
    close conn'

    tlog "Done"
    putMVar done ()

  takeMVar done

-- | Test that we can connect an endpoint to itself multiple times
testConnectToSelfTwice :: Transport -> Int -> IO ()
testConnectToSelfTwice transport numPings = do
  done <- newEmptyMVar
  endpoint <- expectRight "testConnectToSelfTwice: newEndPoint" =<< newEndPoint transport

  tlog "Talk to myself"

  -- An MVar to ensure that the node which sends pingA will connect first, as
  -- this determines the order of the events given out by 'collect' and is
  -- essential for the equality test there.
  firstConnectionMade <- newEmptyMVar

  -- One thread to write to the endpoint using the first connection
  forkTry $ do
    tlog "Creating self-connection"
    conn1 <- expectRight "testConnectToSelfTwice: connect (conn1)"
               =<< connect endpoint (address endpoint) ReliableOrdered defaultConnectHints
    putMVar firstConnectionMade ()

    tlog $ "writing"

    tlog $ "Sending ping"
    replicateM_ numPings $ send conn1 ["pingA"]

    tlog $ "Closing connection"
    close conn1

  -- One thread to write to the endpoint using the second connection
  forkTry $ do
    takeMVar firstConnectionMade
    tlog "Creating self-connection"
    conn2 <- expectRight "testConnectToSelfTwice: connect (conn2)"
               =<< connect endpoint (address endpoint) ReliableOrdered defaultConnectHints
    tlog $ "writing"

    tlog $ "Sending ping"
    replicateM_ numPings $ send conn2 ["pingB"]

    tlog $ "Closing connection"
    close conn2

  -- And one thread to read
  forkTry $ do
    tlog $ "reading"

    collected <- collect endpoint (Just (2 * (numPings + 2))) Nothing
    case collected of
      [(_, events1), (_, events2)] -> do
        expectEq "testConnectToSelfTwice: pingA stream" (replicate numPings ["pingA"]) events1
        expectEq "testConnectToSelfTwice: pingB stream" (replicate numPings ["pingB"]) events2
      _ ->
        ioError $ userError $
          "testConnectToSelfTwice: expected two collected connections, got " ++ show (length collected)

    tlog "Done"
    putMVar done ()

  takeMVar done

-- | Test that we self-connections no longer work once we close our endpoint
-- or our transport
testCloseSelf :: IO (Either String Transport) -> IO ()
testCloseSelf newTransport = do
  transport <- expectRight "testCloseSelf: newTransport" =<< newTransport
  endpoint1 <- expectRight "testCloseSelf: newEndPoint (1)" =<< newEndPoint transport
  endpoint2 <- expectRight "testCloseSelf: newEndPoint (2)" =<< newEndPoint transport
  conn1     <- expectRight "testCloseSelf: connect (conn1)" =<< connect endpoint1 (address endpoint1) ReliableOrdered defaultConnectHints
  _         <- expectConnectionOpened =<< receive endpoint1
  conn2     <- expectRight "testCloseSelf: connect (conn2)" =<< connect endpoint1 (address endpoint1) ReliableOrdered defaultConnectHints
  _         <- expectConnectionOpened =<< receive endpoint1
  conn3     <- expectRight "testCloseSelf: connect (conn3)" =<< connect endpoint2 (address endpoint2) ReliableOrdered defaultConnectHints
  _         <- expectConnectionOpened =<< receive endpoint2

  -- Close the conneciton and try to send
  close conn1
  _ <- expectConnectionClosed =<< receive endpoint1
  send conn1 ["ping"] >>= expectTransportError "testCloseSelf: send on closed conn1" SendClosed

  -- Close the first endpoint. We should not be able to use the first
  -- connection anymore, or open more self connections, but the self connection
  -- to the second endpoint should still be fine
  closeEndPoint endpoint1
  expectEndPointClosed =<< receive endpoint1
  send conn2 ["ping"] >>= expectTransportError "testCloseSelf: send on conn2 after endpoint1 close" SendFailed
  connect endpoint1 (address endpoint1) ReliableOrdered defaultConnectHints
    >>= expectTransportError "testCloseSelf: connect on closed endpoint1" ConnectFailed
  expectRight "testCloseSelf: send on conn3 (still valid)" =<< send conn3 ["ping"]
  _ <- expectReceived =<< receive endpoint2

  -- Close the transport; now the second should no longer work
  closeTransport transport
  send conn3 ["ping"] >>= expectTransportError "testCloseSelf: send on conn3 after transport close" SendFailed
  connect endpoint2 (address endpoint2) ReliableOrdered defaultConnectHints
    >>= expectTransportError "testCloseSelf: connect after transport close" ConnectFailed

-- | Test various aspects of 'closeEndPoint'
testCloseEndPoint :: Transport -> Int -> IO ()
testCloseEndPoint transport _ = do
  serverFirstTestDone <- newEmptyMVar
  serverDone <- newEmptyMVar
  clientDone <- newEmptyMVar
  clientAddr1 <- newEmptyMVar
  clientAddr2 <- newEmptyMVar
  serverAddr <- newEmptyMVar

  -- Server
  forkTry $ do
    endpoint <- expectRight "testCloseEndPoint (server): newEndPoint" =<< newEndPoint transport
    putMVar serverAddr (address endpoint)

    -- First test (see client)
    do
      _theirAddr <- readMVar clientAddr1
      (cid, rel, addr) <- expectConnectionOpened =<< receive endpoint
      expectEq "testCloseEndPoint (server, 1): opened reliability" ReliableOrdered rel
      -- Ensure that connecting to the supplied address reaches the peer.
      conn <- expectRight "testCloseEndPoint (server, 1): connect back" =<< connect endpoint addr ReliableOrdered defaultConnectHints
      close conn
      putMVar serverFirstTestDone ()
      ev <- receive endpoint
      expectEq "testCloseEndPoint (server, 1): ConnectionClosed" (ConnectionClosed cid) ev
      putMVar serverAddr (address endpoint)

    -- Second test
    do
      theirAddr <- readMVar clientAddr2

      (cid, rel, addr) <- expectConnectionOpened =<< receive endpoint
      expectEq "testCloseEndPoint (server, 2): opened reliability" ReliableOrdered rel
      -- Ensure that connecting to the supplied address reaches the peer.
      conn1 <- expectRight "testCloseEndPoint (server, 2): connect via supplied addr"
                 =<< connect endpoint addr ReliableOrdered defaultConnectHints
      close conn1
      ev1 <- receive endpoint
      expectEq "testCloseEndPoint (server, 2): ping echo" (Received cid ["ping"]) ev1

      conn2 <- expectRight "testCloseEndPoint (server, 2): connect to theirAddr"
                 =<< connect endpoint theirAddr ReliableOrdered defaultConnectHints
      send conn2 ["pong"]

      ev2 <- receive endpoint
      expectEq "testCloseEndPoint (server, 2): ConnectionClosed" (ConnectionClosed cid) ev2
      ev3 <- receive endpoint
      expectEq "testCloseEndPoint (server, 2): connection lost"
               (ErrorEvent (TransportError (EventConnectionLost theirAddr) ""))
               ev3

      send conn2 ["pong2"] >>= expectTransportError "testCloseEndPoint (server, 2): send after loss" SendFailed

    putMVar serverDone ()

  -- Client
  forkTry $ do

    -- First test: close endpoint with one outgoing but no incoming connections
    do
      theirAddr <- takeMVar serverAddr
      endpoint <- expectRight "testCloseEndPoint (client, 1): newEndPoint" =<< newEndPoint transport
      putMVar clientAddr1 (address endpoint)

      -- Connect to the server, then close the endpoint without disconnecting explicitly
      _ <- expectRight "testCloseEndPoint (client, 1): connect" =<< connect endpoint theirAddr ReliableOrdered defaultConnectHints
      (cid, _, _) <- expectConnectionOpened =<< receive endpoint
      evClose <- receive endpoint
      expectEq "testCloseEndPoint (client, 1): ConnectionClosed" (ConnectionClosed cid) evClose
      -- Don't close before the remote server had a chance to digest the
      -- connection.
      readMVar serverFirstTestDone
      closeEndPoint endpoint
      expectEndPointClosed =<< receive endpoint

    -- Second test: close endpoint with one outgoing and one incoming connection
    do
      theirAddr <- takeMVar serverAddr
      endpoint <- expectRight "testCloseEndPoint (client, 2): newEndPoint" =<< newEndPoint transport
      putMVar clientAddr2 (address endpoint)

      conn <- expectRight "testCloseEndPoint (client, 2): connect" =<< connect endpoint theirAddr ReliableOrdered defaultConnectHints
      (cid, _, _) <- expectConnectionOpened =<< receive endpoint
      evClose <- receive endpoint
      expectEq "testCloseEndPoint (client, 2): server-closed connection" (ConnectionClosed cid) evClose
      send conn ["ping"]

      -- Reply from the server
      (cid', rel, _addr) <- expectConnectionOpened =<< receive endpoint
      expectEq "testCloseEndPoint (client, 2): reply reliability" ReliableOrdered rel
      ev <- receive endpoint
      expectEq "testCloseEndPoint (client, 2): pong echo" (Received cid' ["pong"]) ev

      -- Close the endpoint
      closeEndPoint endpoint
      expectEndPointClosed =<< receive endpoint

      -- Attempt to send should fail with connection closed
      send conn ["ping2"] >>= expectTransportError "testCloseEndPoint (client, 2): send after close" SendFailed

      -- An attempt to close the already closed connection should just return
      close conn

      -- And so should an attempt to connect
      connect endpoint theirAddr ReliableOrdered defaultConnectHints
        >>= expectTransportError "testCloseEndPoint (client, 2): connect after close" ConnectFailed

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
    transport <- expectRight "testCloseTransport (server): newTransport" =<< newTransport
    endpoint <- expectRight "testCloseTransport (server): newEndPoint" =<< newEndPoint transport
    putMVar serverAddr (address endpoint)

    -- Client sets up first endpoint
    theirAddr1 <- readMVar clientAddr1
    (cid1, rel1, addr) <- expectConnectionOpened =<< receive endpoint
    expectEq "testCloseTransport (server): reliability (1)" ReliableOrdered rel1
    -- Test that the address given does indeed point back to the client
    connA <- expectRight "testCloseTransport (server): connect via theirAddr1"
               =<< connect endpoint theirAddr1 ReliableOrdered defaultConnectHints
    close connA
    connB <- expectRight "testCloseTransport (server): connect via opened addr"
               =<< connect endpoint addr ReliableOrdered defaultConnectHints
    close connB

    -- Client sets up second endpoint
    theirAddr2 <- readMVar clientAddr2

    (cid2, rel2, addr') <- expectConnectionOpened =<< receive endpoint
    expectEq "testCloseTransport (server): reliability (2)" ReliableOrdered rel2
    -- We're going to use addr' to connect back to the server, which tests
    -- that it's a valid address (but not *necessarily* == to theirAddr2

    evPing <- receive endpoint
    expectEq "testCloseTransport (server): ping on cid2" (Received cid2 ["ping"]) evPing

    connC <- expectRight "testCloseTransport (server): connect via theirAddr2"
               =<< connect endpoint theirAddr2 ReliableOrdered defaultConnectHints
    send connC ["pong"]
    close connC
    conn <- expectRight "testCloseTransport (server): connect via addr'"
              =<< connect endpoint addr' ReliableOrdered defaultConnectHints
    send conn ["pong"]

    -- Client now closes down its transport. We should receive connection closed messages (we don't know the precise order, however)
    -- TODO: should we get an EventConnectionLost for theirAddr1? We have no outgoing connections
    evs <- replicateM 3 $ receive endpoint
    let expected = [ ConnectionClosed cid1
                   , ConnectionClosed cid2
                   -- , ErrorEvent (TransportError (EventConnectionLost theirAddr1) "")
                   , ErrorEvent (TransportError (EventConnectionLost addr') "")
                   ]
    expectTrue ("testCloseTransport (server): events interleaving " ++ show evs) $
      expected `elem` permutations evs

    -- An attempt to send to the endpoint should now fail
    send conn ["pong2"] >>= expectTransportError "testCloseTransport (server): send after transport close" SendFailed

    putMVar serverDone ()

  -- Client
  forkTry $ do
    transport <- expectRight "testCloseTransport (client): newTransport" =<< newTransport
    theirAddr <- readMVar serverAddr

    -- Set up endpoint with one outgoing but no incoming connections
    endpoint1 <- expectRight "testCloseTransport (client): newEndPoint (1)" =<< newEndPoint transport
    putMVar clientAddr1 (address endpoint1)

    -- Connect to the server, then close the endpoint without disconnecting explicitly
    _ <- expectRight "testCloseTransport (client): initial connect" =<< connect endpoint1 theirAddr ReliableOrdered defaultConnectHints
    -- Server connects back to verify that both addresses they have for us
    -- are suitable to reach us.
    (cidA, relA, _) <- expectConnectionOpened =<< receive endpoint1
    expectEq "testCloseTransport (client, 1a): reliability" ReliableOrdered relA
    evA <- receive endpoint1
    expectEq "testCloseTransport (client, 1a): ConnectionClosed" (ConnectionClosed cidA) evA
    (cidB, relB, _) <- expectConnectionOpened =<< receive endpoint1
    expectEq "testCloseTransport (client, 1b): reliability" ReliableOrdered relB
    evB <- receive endpoint1
    expectEq "testCloseTransport (client, 1b): ConnectionClosed" (ConnectionClosed cidB) evB

    -- Set up an endpoint with one outgoing and one incoming connection
    endpoint2 <- expectRight "testCloseTransport (client): newEndPoint (2)" =<< newEndPoint transport
    putMVar clientAddr2 (address endpoint2)

    -- The outgoing connection.
    conn <- expectRight "testCloseTransport (client): outgoing connect" =<< connect endpoint2 theirAddr ReliableOrdered defaultConnectHints
    send conn ["ping"]

    -- Reply from the server. It will connect twice, using both addresses
    -- (the one that the client sees, and the one that the server sees).
    (cidC, relC, _) <- expectConnectionOpened =<< receive endpoint2
    expectEq "testCloseTransport (client, 2a): reliability" ReliableOrdered relC
    evPongA <- receive endpoint2
    expectEq "testCloseTransport (client, 2a): pong" (Received cidC ["pong"]) evPongA
    evCloseA <- receive endpoint2
    expectEq "testCloseTransport (client, 2a): ConnectionClosed" (ConnectionClosed cidC) evCloseA
    (cidD, relD, _) <- expectConnectionOpened =<< receive endpoint2
    expectEq "testCloseTransport (client, 2b): reliability" ReliableOrdered relD
    evPongB <- receive endpoint2
    expectEq "testCloseTransport (client, 2b): pong" (Received cidD ["pong"]) evPongB

    -- Now shut down the entire transport
    closeTransport transport

    -- Both endpoints should report that they have been closed
    expectEndPointClosed =<< receive endpoint1
    expectEndPointClosed =<< receive endpoint2

    -- Attempt to send should fail with connection closed
    send conn ["ping2"] >>= expectTransportError "testCloseTransport (client): send after transport close" SendFailed

    -- An attempt to close the already closed connection should just return
    close conn

    -- And so should an attempt to connect on either endpoint
    connect endpoint1 theirAddr ReliableOrdered defaultConnectHints
      >>= expectTransportError "testCloseTransport (client): connect via endpoint1" ConnectFailed
    connect endpoint2 theirAddr ReliableOrdered defaultConnectHints
      >>= expectTransportError "testCloseTransport (client): connect via endpoint2" ConnectFailed

    -- And finally, so should an attempt to create a new endpoint
    newEndPoint transport
      >>= expectTransportError "testCloseTransport (client): newEndPoint after close" NewEndPointFailed

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
    endpoint <- expectRight "testConnectClosedEndPoint (server): newEndPoint" =<< newEndPoint transport
    putMVar serverAddr (address endpoint)

    closeEndPoint endpoint
    putMVar serverClosed ()

  -- Client
  forkTry $ do
    endpoint <- expectRight "testConnectClosedEndPoint (client): newEndPoint" =<< newEndPoint transport
    readMVar serverClosed

    (readMVar serverAddr >>= \addr -> connect endpoint addr ReliableOrdered defaultConnectHints)
      >>= expectTransportError "testConnectClosedEndPoint (client): connect to closed endpoint" ConnectNotFound

    putMVar clientDone ()

  takeMVar clientDone

-- | We should receive an exception when doing a 'receive' after we have been
-- notified that an endpoint has been closed
testExceptionOnReceive :: IO (Either String Transport) -> IO ()
testExceptionOnReceive newTransport = do
  transport <- expectRight "testExceptionOnReceive: newTransport" =<< newTransport

  -- Test one: when we close an endpoint specifically
  endpoint1 <- expectRight "testExceptionOnReceive: newEndPoint (1)" =<< newEndPoint transport
  closeEndPoint endpoint1
  expectEndPointClosed =<< receive endpoint1
  _ <- expectLeft "testExceptionOnReceive (1): receive after close"
         =<< trySome (receive endpoint1 >>= evaluate)

  -- Test two: when we close the entire transport
  endpoint2 <- expectRight "testExceptionOnReceive: newEndPoint (2)" =<< newEndPoint transport
  closeTransport transport
  expectEndPointClosed =<< receive endpoint2
  _ <- expectLeft "testExceptionOnReceive (2): receive after close"
         =<< trySome (receive endpoint2 >>= evaluate)

  return ()

-- | Test what happens when the argument to 'send' is an exceptional value
testSendException :: IO (Either String Transport) -> IO ()
testSendException newTransport = do
  transport <- expectRight "testSendException: newTransport" =<< newTransport
  endpoint1 <- expectRight "testSendException: newEndPoint (1)" =<< newEndPoint transport
  endpoint2 <- expectRight "testSendException: newEndPoint (2)" =<< newEndPoint transport

  -- Connect endpoint1 to endpoint2
  conn <- expectRight "testSendException: connect" =<< connect endpoint1 (address endpoint2) ReliableOrdered defaultConnectHints
  _ <- expectConnectionOpened =<< receive endpoint2

  -- Send an exceptional value
  send conn (throw $ userError "uhoh")
    >>= expectTransportError "testSendException: send with exceptional payload" SendFailed

  -- This will have been as a failure to send by endpoint1, which will
  -- therefore have closed the socket. In turn this will have caused endpoint2
  -- to report that the connection was lost
  ev1 <- receive endpoint1
  err1 <- expectErrorEvent ev1
  case err1 of
    TransportError (EventConnectionLost _) _ -> return ()
    _ -> ioError $ userError $ "testSendException: expected EventConnectionLost on endpoint1, got " ++ show ev1
  ev2 <- receive endpoint2
  err2 <- expectErrorEvent ev2
  case err2 of
    TransportError (EventConnectionLost _) _ -> return ()
    _ -> ioError $ userError $ "testSendException: expected EventConnectionLost on endpoint2, got " ++ show ev2

  -- A new connection will re-establish the connection
  conn2 <- expectRight "testSendException: reconnect" =<< connect endpoint1 (address endpoint2) ReliableOrdered defaultConnectHints
  send conn2 ["ping"]
  close conn2

  _                 <- expectConnectionOpened =<< receive endpoint2
  (_, pingPayload)  <- expectReceived        =<< receive endpoint2
  expectEq "testSendException: ping payload" ["ping"] pingPayload
  _                 <- expectConnectionClosed =<< receive endpoint2

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
  transport1 <- expectRight "testKill: newTransport (1)" =<< newTransport
  transport2 <- expectRight "testKill: newTransport (2)" =<< newTransport
  endpoint1 <- expectRight "testKill: newEndPoint (1)" =<< newEndPoint transport1
  endpoint2 <- expectRight "testKill: newEndPoint (2)" =<< newEndPoint transport2

  threads <- replicateM numThreads . forkIO $ do
    randomThreadDelay 100
    bracket (connect endpoint1 (address endpoint2) ReliableOrdered defaultConnectHints)
            -- Note that we should not insert a randomThreadDelay into the
            -- exception handler itself as this means that the exception handler
            -- could be interrupted and we might not close
            (\econn -> do
              conn <- expectRight "testKill (bracket release): connect" econn
              close conn)
            (\econn -> do
              conn <- expectRight "testKill (bracket use): connect" econn
              randomThreadDelay 100
              expectRight "testKill: send" =<< send conn ["ping"]
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
  [aGo,   bGo]   <- replicateM 2 newEmptyMVar
  [aTimeout, bTimeout] <- replicateM 2 newEmptyMVar

  let hints = defaultConnectHints {
                connectTimeout = Just 5000000
              }

  -- A
  forkTry $ do
    endpoint <- expectRight "testCrossing (A): newEndPoint" =<< newEndPoint transport
    putMVar aAddr (address endpoint)
    theirAddress <- readMVar bAddr

    replicateM_ numRepeats $ do
      takeMVar aGo >> yield
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
    endpoint <- expectRight "testCrossing (B): newEndPoint" =<< newEndPoint transport
    putMVar bAddr (address endpoint)
    theirAddress <- readMVar aAddr

    replicateM_ numRepeats $ do
      takeMVar bGo >> yield
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
    b <- randomIO
    if b then do putMVar aGo () ; putMVar bGo ()
         else do putMVar bGo () ; putMVar aGo ()
    yield
    takeMVar aDone
    takeMVar bDone

-- Transport tests
testTransport :: IO (Either String Transport) -> IO ()
testTransport = testTransportWithFilter (const True)

testTransportWithFilter :: (String -> Bool) -> IO (Either String Transport) -> IO ()
testTransportWithFilter p newTransport = do
  transport <- expectRight "testTransportWithFilter: newTransport" =<< newTransport
  runTests $ filter (p . fst)
    [ ("PingPong",              testPingPong transport numPings)
    , ("EndPoints",             testEndPoints transport numPings)
    , ("Connections",           testConnections transport numPings)
    , ("CloseOneConnection",    testCloseOneConnection transport numPings)
    , ("CloseOneDirection",     testCloseOneDirection transport numPings)
    , ("CloseReopen",           testCloseReopen transport numPings)
    , ("ParallelConnects",      testParallelConnects transport numPings)
    , ("SelfSend",              testSelfSend transport)
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


-- Test that list is a union of stream message, with preserved ordering
-- within each stream.
-- Note: this function may not work if different streams contains equal
-- messages.
testStreams :: Eq a => [a] -> [[a]] -> Bool
testStreams []      ys = all null ys
testStreams (x:xs)  ys =
    case go [] ys of
      []  -> False
      ys' -> testStreams xs ys'
  where
    go _ [] = []
    go c ([]:zss) = go c zss
    go c (z'@(z:zs):zss)
        |  x == z    = (zs:c)++zss
        |  otherwise = go (z':c) zss
