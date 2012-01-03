module DemoTransport where

import Network.Transport
import qualified Network.Transport.MVar
import Network.Transport.TCP (mkTransport, TCPConfig (..))

import Control.Concurrent
import Control.Monad

import qualified Data.ByteString.Char8 as BS

import Debug.Trace

-------------------------------------------
-- Example program using backend directly
--

-- | Check if multiple messages can be sent on the same connection.
demo0 :: IO ()
demo0 = do
  trans <- mkTransport $ TCPConfig undefined "127.0.0.1" "8080"

  (sendAddr, receiveEnd) <- newConnection trans

  forkIO $ logServer "logServer" receiveEnd
  threadDelay 100000

  sendEnd <- connect sendAddr

  mapM_ (\n -> send sendEnd [BS.pack ("hello " ++ show n)]) [1 .. 10]
  threadDelay 100000

-- | Check endpoint serialization and deserialization.
demo1 :: IO ()
demo1 = do
  -- trans <- mkTransport
  trans <- mkTransport $ TCPConfig undefined "127.0.0.1" "8080"

  (sendAddr, receiveEnd) <- newConnection trans

  forkIO $ logServer "logServer" receiveEnd
  threadDelay 100000

  sendEnd <- connect sendAddr

  -- This use of Just is slightly naughty
  let Just sendAddr' = deserialize trans (serialize sendAddr)
  sendEnd' <- connect sendAddr'

  send sendEnd  [BS.pack "hello 1"]
  send sendEnd' [BS.pack "hello 2"]
  threadDelay 100000

-- | Check that messages can be sent before receive is set up.
demo2 :: IO ()
demo2 = do
  -- trans <- mkTransport
  trans <- mkTransport $ TCPConfig undefined "127.0.0.1" "8080"

  (sendAddr, receiveEnd) <- newConnection trans

  sendEnd <- connect sendAddr
  forkIO $ send sendEnd [BS.pack "hello 1"]
  threadDelay 100000

  forkIO $ logServer "logServer" receiveEnd
  return ()

-- | Check that two different transports can be created.
demo3 :: IO ()
demo3 = do
  trans1 <- mkTransport $ TCPConfig undefined "127.0.0.1" "8080"
  trans2 <- mkTransport $ TCPConfig undefined "127.0.0.1" "8081"

  (sendAddr1, receiveEnd1) <- newConnection trans1
  (sendAddr2, receiveEnd2) <- newConnection trans2

  forkIO $ logServer "logServer1" receiveEnd1
  forkIO $ logServer "logServer2" receiveEnd2

  sendEnd1 <- connect sendAddr1
  sendEnd2 <- connect sendAddr2

  send sendEnd1 [BS.pack "hello1"]
  send sendEnd2 [BS.pack "hello2"]

-- | Check that two different connections on the same transport can be created.
demo4 :: IO ()
demo4 = do
  trans <- mkTransport $ TCPConfig undefined "127.0.0.1" "8080"
  -- trans <- Network.Transport.MVar.mkTransport

  (sendAddr1, receiveEnd1) <- newConnection trans
  (sendAddr2, receiveEnd2) <- newConnection trans

  forkIO $ logServer "logServer1" receiveEnd1
  forkIO $ logServer "logServer2" receiveEnd2

  sendEnd1 <- connect sendAddr1
  sendEnd2 <- connect sendAddr2

  send sendEnd1 [BS.pack "hello1"]
  send sendEnd2 [BS.pack "hello2"]

logServer :: String -> ReceiveEnd -> IO ()
logServer name receiveEnd = forever $ do
  x <- receive receiveEnd
  trace (name ++ ": " ++ show x) $ return ()