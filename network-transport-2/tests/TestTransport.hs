module TestTransport where

import Prelude hiding (catch)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar, readMVar)
import Control.Monad (replicateM, replicateM_, when, guard, forM_)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (evaluate, throw, catch, SomeException)
import Control.Applicative ((<$>))
import Network.Transport
import Network.Transport.Internal (tlog)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, delete, findWithDefault, adjust, null, toList, map)
import System.IO (hFlush, stdout)
import System.Timeout (timeout)

-- Server that echoes messages straight back to the origin endpoint.
echoServer :: EndPoint -> IO ()
echoServer endpoint = do
    tlog "Echo server"
    go Map.empty
  where
    go :: Map ConnectionId Connection -> IO () 
    go cs = do
      event <- receive endpoint
      tlog $ "Got event " ++ show event
      case event of
        ConnectionOpened cid rel addr -> do
          Right conn <- connect endpoint addr rel 
          go (Map.insert cid conn cs) 
        Received cid payload -> do
          send (Map.findWithDefault (error $ "Received: Invalid cid " ++ show cid) cid cs) payload 
          go cs
        ConnectionClosed cid -> do 
          close (Map.findWithDefault (error $ "ConnectionClosed: Invalid cid " ++ show cid) cid cs)
          go (Map.delete cid cs) 
        ReceivedMulticast _ _ -> 
          -- Ignore
          go cs

expect :: EndPoint -> (Event -> Bool) -> IO ()
expect endpoint predicate = do
  event <- receive endpoint
  tlog $ "Got event " ++ show event
  mbool <- catch (Right <$> evaluate (predicate event)) (return . Left)
  case mbool of
    Left err    -> do tlog $ "Unexpected event " ++ show event 
                      throw (err :: SomeException) 
    Right False -> do tlog $ "Unexpected event " ++ show event 
                      fail "Unexpected event"
    _           -> return ()

ping :: EndPoint -> EndPointAddress -> Int -> ByteString -> IO ()
ping endpoint server numPings msg = do
  -- Open connection to the server
  tlog "Connect to echo server"
  Right conn <- connect endpoint server ReliableOrdered

  -- Wait for the server to open reply connection
  tlog "Wait for ConnectionOpened message"
  expect endpoint (\(ConnectionOpened _ _ _) -> True)

  -- Send pings and wait for reply
  tlog "Send ping and wait for reply"
  replicateM_ numPings $ do
      send conn [msg]
      expect endpoint (\(Received _ [reply]) -> reply == msg)

  -- Close the connection
  tlog "Close the connection"
  close conn

  -- Wait for the server to close its connection to us
  tlog "Wait for ConnectionClosed message"
  expect endpoint (\(ConnectionClosed _) -> True)

  -- Done
  tlog "Ping client done"
    
-- Basic ping test
testPingPong :: Transport -> Int -> IO () 
testPingPong transport numPings = do
  tlog "Starting ping pong test"
  server <- spawn transport echoServer
  result <- newEmptyMVar

  -- Client 
  forkIO $ do
    tlog "Ping client"
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "ping"
    putMVar result () 
  
  takeMVar result

-- Test that endpoints don't get confused
testEndPoints :: Transport -> Int -> IO () 
testEndPoints transport numPings = do
  server <- spawn transport echoServer
  dones <- replicateM 2 newEmptyMVar

  forM_ (zip dones ['A'..]) $ \(done, name) -> forkIO $ do 
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
  forkIO $ do
    Right endpoint <- newEndPoint transport

    -- Open two connections to the server
    Right conn1 <- connect endpoint server ReliableOrdered
    ConnectionOpened serv1 _ _ <- receive endpoint
   
    Right conn2 <- connect endpoint server ReliableOrdered
    ConnectionOpened serv2 _ _ <- receive endpoint

    -- One thread to send "pingA" on the first connection
    forkIO $ replicateM_ numPings $ send conn1 ["pingA"]

    -- One thread to send "pingB" on the second connection
    forkIO $ replicateM_ numPings $ send conn2 ["pingB"]

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

-- Test that closing one connection does not close the other
testCloseOneConnection :: Transport -> Int -> IO ()
testCloseOneConnection transport numPings = do
  server <- spawn transport echoServer
  result <- newEmptyMVar
  
  -- Client
  forkIO $ do
    Right endpoint <- newEndPoint transport

    -- Open two connections to the server
    Right conn1 <- connect endpoint server ReliableOrdered
    ConnectionOpened serv1 _ _ <- receive endpoint
   
    Right conn2 <- connect endpoint server ReliableOrdered
    ConnectionOpened serv2 _ _ <- receive endpoint

    -- One thread to send "pingA" on the first connection
    forkIO $ do
      replicateM_ numPings $ send conn1 ["pingA"]
      close conn1
      
    -- One thread to send "pingB" on the second connection
    forkIO $ replicateM_ (numPings * 2) $ send conn2 ["pingB"]

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

-- Test that if A connects to B and B connects to A, B can still send to A after
-- A closes its connection to B (for instance, in the TCP transport, the socket pair
-- connecting A and B should not yet be closed).
testCloseOneDirection :: Transport -> Int -> IO ()
testCloseOneDirection transport numPings = do
  addrA <- newEmptyMVar
  addrB <- newEmptyMVar
  doneA <- newEmptyMVar
  doneB <- newEmptyMVar

  -- A
  forkIO $ do
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
  forkIO $ do
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

collect :: EndPoint -> Int -> IO ([(ConnectionId, [[ByteString]])]) 
collect endPoint numEvents = go numEvents (Map.empty) (Map.empty)
  where
    go 0 !open !closed = if Map.null open 
                         then return . Map.toList . Map.map reverse $ closed
                         else fail "Open connections"
    go !n !open !closed = do
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

-- Open connection, close it, then reopen it
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
  forkIO $ do
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
  forkIO $ do
    Right endpoint <- newEndPoint transport
    putMVar addrB (address endpoint)

    eventss <- collect endpoint (numRepeats * (numPings + 2))

    forM_ (zip [1 .. numRepeats] eventss) $ \(i, (_, events)) -> do
      forM_ (zip [1 .. numPings] events) $ \(j, event) -> do
        guard (event == [pack $ "ping" ++ show i ++ "/" ++ show j])

    putMVar doneB ()

  takeMVar doneB

-- Test lots of parallel connection attempts
testParallelConnects :: Transport -> Int -> IO ()
testParallelConnects transport numPings = do
  server <- spawn transport echoServer
  done   <- newEmptyMVar 

  Right endpoint <- newEndPoint transport

  -- Spawn lots of clients
  forM_ [1 .. numPings] $ \i -> forkIO $ do 
    Right conn <- connect endpoint server ReliableOrdered
    send conn [pack $ "ping" ++ show i]
    send conn [pack $ "ping" ++ show i]
    close conn

  forkIO $ do
    eventss <- collect endpoint (numPings * 4)
    -- Check that no pings got sent to the wrong connection
    forM_ eventss $ \(_, [[ping1], [ping2]]) -> 
      guard (ping1 == ping2)
    putMVar done ()

  takeMVar done

runTestIO :: String -> IO () -> IO ()
runTestIO description test = do
  putStr $ "Running " ++ show description ++ ": "
  hFlush stdout
  test 
  putStrLn "ok"
  
runTest :: String -> (Transport -> Int -> IO ()) -> ReaderT (Transport, Int) IO ()
runTest description test = do
  (transport, numPings) <- ask 
  done <- liftIO $ timeout 10000000 $ runTestIO description (test transport numPings) 
  case done of 
    Just () -> return ()
    Nothing -> error "timeout"

-- Transport tests
testTransport :: Transport -> IO ()
testTransport transport = flip runReaderT (transport, 10000) $ do
  runTest "PingPong" testPingPong
  runTest "EndPoints" testEndPoints
  runTest "Connections" testConnections 
  runTest "CloseOneConnection" testCloseOneConnection
  runTest "CloseOneDirection" testCloseOneDirection
  runTest "CloseReopen" testCloseReopen
  runTest "ParallelConnects" testParallelConnects
