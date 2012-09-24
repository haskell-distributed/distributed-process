import System.Environment (getArgs)
import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure

#ifdef USE_SIMPLELOCALNET
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
#endif

--------------------------------------------------------------------------------
-- Backend agnostic code                                                      --
--------------------------------------------------------------------------------

fib :: Integer -> Integer
fib = go (0, 1)
  where
    go (!a, !b) !n | n == 0    = a
                   | otherwise = go (b, a + b) (n - 1)

slave :: () -> Process ()
slave () = forever $ do
  (pid, n) <- expect
  send pid (fib n)

remotable ['slave]

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  us <- getSelfPid

  -- Start processes on the slaves that compute Fibonacci numbers
  slaveProcesses <- forM slaves $ flip spawn ($(mkClosure 'slave) ())

  -- Distribute 1 .. n amongst the slave processes 
  forM_ (zip [1 .. n] (cycle slaveProcesses)) $ \(m, them) -> 
    send them (us, m)

  -- Wait for the result
  partials <- replicateM (fromInteger n) (expect :: Process Integer)

  -- And return the sum
  return (sum partials) 

rtable :: RemoteTable
rtable = __remoteTable initRemoteTable 

--------------------------------------------------------------------------------
-- Using the SimpleLocalnet backend                                           --
--------------------------------------------------------------------------------

#ifdef USE_SIMPLELOCALNET
main :: IO ()
main = do
  args <- getArgs

  case args of
    ["master", host, port, n] -> do
      backend <- initializeBackend host port rtable 
      startMaster backend $ \slaves -> do
        result <- master (read n) slaves
        liftIO $ print result 
    ["slave", host, port] -> do
      backend <- initializeBackend host port rtable 
      startSlave backend
#endif -- USE_SIMPLELOCALNET
