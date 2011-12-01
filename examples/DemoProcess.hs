module DemoProcess where

import Control.Distributed.Process
import Control.Concurrent (threadDelay)

import Network.Transport.MVar (mkTransport)

demo1 = do
  trans <- mkTransport
  node  <- newLocalNode trans
  print "foo"
  runProcess node $ do
    liftIO $ print "bar"
    lpid1 <- spawnLocal (logger 1)
--    liftIO $ print "baz"
--    lpid2 <- spawnLocal (logger 2)
    
    spawnLocal (chatty "jim1" lpid1)
--    spawnLocal (chatty "jim2" lpid2)
    spawnLocal (chatty "bob1" lpid1)
--    spawnLocal (chatty "bob2" lpid2)
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
  liftIO $ putStrLn $ show n ++ ": " ++ str
  logger (n+1)
