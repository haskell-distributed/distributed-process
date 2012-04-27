module TestTransport where

import Control.Concurrent (forkIO)
-- import Control.Concurrent (myThreadId)
import Control.Monad (replicateM, replicateM_, when)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Network.Transport
import Data.ByteString (ByteString)
import Data.ByteString.Char8 ()
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, delete, findWithDefault)
import Control.Monad.Reader (ReaderT, runReaderT, ask)
import Control.Monad.IO.Class (liftIO)
import System.IO (hFlush, stdout)
import System.Timeout (timeout)

-- Logging (for debugging)
tlog :: String -> IO ()
tlog _ = return ()
{-
tlog msg = do
  tid <- myThreadId
  putStrLn $ show tid ++ ": "  ++ msg
-}

-- Server that echoes messages straight back to the origin endpoint.
echoServer :: EndPoint -> IO ()
echoServer endpoint = do
    tlog "Echo server"
    go Map.empty
  where
    go :: Map ConnectionId Connection -> IO () 
    go cs = do
      event <- receive endpoint
      tlog (show event)
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

ping :: EndPoint -> EndPointAddress -> Int -> ByteString -> IO ()
ping endpoint server numPings msg = do
  -- Open connection to the server
  tlog "Open connection"
  Right conn <- connect endpoint server ReliableOrdered

  -- Wait for the server to open reply connection
  tlog "Wait for ConnectionOpened message"
  ConnectionOpened _ _ _ <- receive endpoint

  -- Send pings and wait for reply
  tlog "Send ping and wait for reply"
  replicateM_ numPings $ do
      send conn [msg]
      event <- receive endpoint
      case event of
        Received _ [reply] | reply == msg -> 
          return ()
        _ -> 
          error $ "Unexpected event " ++ show event 

  -- Close the connection
  tlog "Close the connection"
  close conn
    
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
  [resultA, resultB] <- replicateM 2 newEmptyMVar 

  -- Client A
  forkIO $ do
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "pingA"
    putMVar resultA () 

  -- Client B
  forkIO $ do
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "pingB"
    putMVar resultB () 

  mapM_ takeMVar [resultA, resultB] 

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
    Right endpoint <- newEndPoint transport
    putMVar addrA (address endpoint)

    -- Connect to B
    Right conn <- takeMVar addrB >>= \addr -> connect endpoint addr ReliableOrdered 

    -- Wait for B to connect to us
    ConnectionOpened _ _ _ <- receive endpoint

    -- Send pings to B
    replicateM_ numPings $ send conn ["ping"] 

    -- Close our connection to B
    close conn

    -- Wait for B's pongs
    replicateM_ numPings $ do Received _ _ <- receive endpoint ; return ()

    -- Wait for B to close it's connection to us
    -- TODO: this message is not yet sent
    -- ConnectionClosed _ <- receive endpoint

    -- Done
    putMVar doneA ()

  -- B
  forkIO $ do
    Right endpoint <- newEndPoint transport
    putMVar addrB (address endpoint)

    -- Wait for A to connect
    ConnectionOpened _ _ _ <- receive endpoint

    -- Connect to A
    Right conn <- takeMVar addrA >>= \addr -> connect endpoint addr ReliableOrdered 

    -- Wait for A's pings
    replicateM_ numPings $ do Received _ _ <- receive endpoint ; return ()

    -- Wait for A to close it's connection to us
    -- TODO: this message is not yet sent
    -- ConnectionClosed _ <- receive endpoint

    -- Send pongs to A
    replicateM_ numPings $ send conn ["pong"]
   
    -- Close our connection to A
    close conn

    -- Done
    putMVar doneB ()

  mapM_ takeMVar [doneA, doneB]


runTestIO :: String -> IO () -> IO ()
runTestIO description test = do
  putStr $ "Running " ++ show description ++ ": "
  hFlush stdout
  test 
  putStrLn "ok"
  
runTest :: String -> (Transport -> Int -> IO ()) -> ReaderT (Transport, Int) IO ()
runTest description test = do
  (transport, numPings) <- ask 
  done <- liftIO $ timeout 5000000 $ runTestIO description (test transport numPings) 
  case done of 
    Just () -> return ()
    Nothing -> error "timeout"

-- Transport tests
testTransport :: Transport -> IO ()
testTransport transport = flip runReaderT (transport, 50000) $ do
  runTest "PingPong" testPingPong
  runTest "EndPoints" testEndPoints
  runTest "Connections" testConnections 
  runTest "CloseOneConnection" testCloseOneConnection
--  runTest "CloseOneDirection" testCloseOneDirection
