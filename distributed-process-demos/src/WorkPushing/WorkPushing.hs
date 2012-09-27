module WorkPushing where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure

fib :: Integer -> Integer
fib = go (0, 1)
  where
    go (!a, !b) !n | n == 0    = a
                   | otherwise = go (b, a + b) (n - 1)

slave :: ProcessId -> Process ()
slave them = forever $ do
  n <- expect
  send them (fib n)

remotable ['slave]

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  us <- getSelfPid

  -- Start processes on the slaves that compute Fibonacci numbers
  slaveProcesses <- forM slaves $ \nid -> spawn nid ($(mkClosure 'slave) us)

  -- Distribute 1 .. n amongst the slave processes 
  forM_ (zip [1 .. n] (cycle slaveProcesses)) $ \(m, them) -> send them m 

  -- Wait for the result
  partials <- replicateM (fromIntegral n) (expect :: Process Integer)

  -- And return the sum
  return (sum partials) 
