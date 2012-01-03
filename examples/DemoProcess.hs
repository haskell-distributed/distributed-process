module DemoProcess where

import Control.Distributed.Process
import Control.Concurrent (threadDelay)

import Network.Transport.TCP (mkTransport, TCPConfig (..))

import Debug.Trace

demo1 = do
  trans <- mkTransport $ TCPConfig undefined "127.0.0.1" "8080"
  node  <- newLocalNode trans
  print "Starting node"
  runProcess node $ do
    liftIO $ print "Starting process"
    lpid1 <- spawnLocal (logger 1)
    spawnLocal (chatty "jim1" lpid1)
    spawnLocal (chatty "bob1" lpid1)
    liftIO $ threadDelay 500000
    return ()

chatty :: String -> ProcessId -> Process ()
chatty name target = do
  send target (name ++ " says: hi there")
  liftIO $ threadDelay 500000
  send target (name ++ " says: bye")

logger :: Int -> Process ()
logger n = do
  str <- expect
  liftIO . putStrLn $ show n ++ ": " ++ str
  logger (n+1)
