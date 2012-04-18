module TestTransport where

import Control.Concurrent (forkIO)
import Control.Monad (liftM2, replicateM, replicateM_, when)
import Control.Applicative ((<$>))
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Network.Transport
import Data.ByteString (ByteString)
import Data.ByteString.Char8 ()
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, (!), delete)

type Test = IO Bool

-- Server that echoes messages straight back to the origin endpoint.
echoServer :: EndPoint -> IO ()
echoServer endpoint = go Map.empty
  where
    go :: Map ConnectionId Connection -> IO () 
    go cs = do
      event <- receive endpoint
      case event of
        ConnectionOpened cid rel addr -> do
          Right conn <- connect endpoint addr rel 
          go (Map.insert cid conn cs) 
        Receive cid payload -> do
          send (cs Map.! cid) payload 
          go cs
        ConnectionClosed cid -> do 
          close (cs Map.! cid)
          go (Map.delete cid cs) 
        MulticastReceive _ _ -> 
          -- Ignore
          go cs

ping :: EndPoint -> Address -> Int -> ByteString -> IO ()
ping endpoint server numPings msg = do
  -- Open connection to the server
  Right conn <- connect endpoint server ReliableOrdered

  -- Wait for the server to open reply connection
  ConnectionOpened _ _ _ <- receive endpoint

  -- Send pings and wait for reply
  replicateM_ numPings $ do
      send conn [msg]
      Receive _ [reply] <- receive endpoint
      when (reply /= msg) . error $ "Message mismatch: " ++ show msg ++ " /= " ++ show reply 

  -- Close the connection
  close conn
    
-- Basic ping test
testPingPong :: Transport -> Int -> Test
testPingPong transport numPings = do
  server <- spawn transport echoServer
  result <- newEmptyMVar

  -- Client 
  forkIO $ do
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
            Receive cid [payload] -> do
              when (cid == serv1 && payload /= "pingA") $ error "Wrong message"
              when (cid == serv2 && payload /= "pingB") $ error "Wrong message"
              verifyResponse (n - 1) 
            _ -> 
              verifyResponse n 
    verifyResponse (2 * numPings)

  takeMVar result

-- Transport tests
testTransport :: Transport -> IO Bool
testTransport transport = 
  foldl (liftM2 (&&)) (return True) [ testPingPong    transport 10000
                                    , testEndPoints   transport 10000
                                    , testConnections transport 10000
                                    ]
