module TestTransport where

import Control.Concurrent (forkIO)
-- import Control.Concurrent (myThreadId)
import Control.Monad (liftM2, replicateM, replicateM_, when)
import Control.Applicative ((<$>))
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Network.Transport
import Data.ByteString (ByteString)
import Data.ByteString.Char8 ()
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, (!), delete)

type Test = IO Bool

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
          send (cs Map.! cid) payload 
          go cs
        ConnectionClosed cid -> do 
          close (cs Map.! cid)
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
testPingPong :: Transport -> Int -> Test
testPingPong transport numPings = do
  tlog "Starting ping pong test"
  server <- spawn transport echoServer
  result <- newEmptyMVar

  -- Client 
  forkIO $ do
    tlog "Ping client"
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "ping"
    putStrLn $ "client did " ++ show numPings ++ " pings"
    putMVar result True
  
  takeMVar result

-- Test that endpoints don't get confused
testEndPoints :: Transport -> Int -> Test
testEndPoints transport numPings = do
  server <- spawn transport echoServer
  [resultA, resultB] <- replicateM 2 newEmptyMVar 

  -- Client A
  forkIO $ do
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "pingA"
    putStrLn $ "client A did " ++ show numPings ++ " pings"
    putMVar resultA True

  -- Client B
  forkIO $ do
    Right endpoint <- newEndPoint transport
    ping endpoint server numPings "pingB"
    putStrLn $ "client B did " ++ show numPings ++ " pings"
    putMVar resultB True

  and <$> mapM takeMVar [resultA, resultB] 

-- Test that connections don't get confused
testConnections :: Transport -> Int -> Test
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
    forkIO $ do
      replicateM_ numPings $ send conn1 ["pingA"]
      putStrLn $ "client A did " ++ show numPings ++ " pings"

    -- One thread to send "pingB" on the second connection
    forkIO $ do
      replicateM_ numPings $ send conn2 ["pingB"]
      putStrLn $ "client B did " ++ show numPings ++ " pings"

    -- Verify server responses 
    let verifyResponse 0 = putMVar result True
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

-- Transport tests
testTransport :: Transport -> IO Bool
testTransport transport = do 
  tlog "Starting transport tests"
  foldl (liftM2 (&&)) (return True) [ testPingPong    transport 10000
                                    , testEndPoints   transport 10000
                                    , testConnections transport 10000
                                    ]
