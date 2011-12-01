module DemoTransport where

import Network.Transport
import Network.Transport.MVar (mkTransport)

import Control.Concurrent
import qualified Data.ByteString.Char8 as BS

-------------------------------------------
-- Example program using backend directly
--

-- check the endpoint serialisation works
demo1 :: IO ()
demo1 = do
  trans <- mkTransport

  (sendAddr, receiveEnd) <- newConnection trans

  forkIO $ logServer receiveEnd
  threadDelay 100000

  sendEnd <- connect sendAddr

  -- This use of Just is slightly naughty
  let Just sendAddr' = deserialize trans (serialize sendAddr)
  sendEnd' <- connect sendAddr'

  send sendEnd  [BS.pack "hello 1"]
  send sendEnd' [BS.pack "hello 2"]
  threadDelay 100000

-- check that we can send before any corresponding receive
demo2 :: IO ()
demo2 = do
  trans <- mkTransport

  (sendAddr, receiveEnd) <- newConnection trans

  sendEnd <- connect sendAddr

  forkIO $ send sendEnd [BS.pack "hello 1"]
  threadDelay 100000
  forkIO $ logServer receiveEnd
  threadDelay 100000
  forkIO $ send sendEnd [BS.pack "hello 2"]
  threadDelay 100000

logServer :: ReceiveEnd -> IO ()
logServer receiveEnd = do
  x <- receive receiveEnd
  print x
  logServer receiveEnd
