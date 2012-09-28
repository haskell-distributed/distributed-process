module WorkPushing where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import PrimeFactors

slave :: ProcessId -> Process ()
slave them = forever $ do
  n <- expect
  send them (numPrimeFactors n)

remotable ['slave]

-- | Wait for n integers and sum them all up
sumIntegers :: Int -> Process Integer
sumIntegers = go 0
  where
    go :: Integer -> Int -> Process Integer
    go !acc 0 = return acc
    go !acc n = do
      m <- expect
      go (acc + m) (n - 1)

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  us <- getSelfPid

  -- Start slave processes 
  slaveProcesses <- forM slaves $ \nid -> spawn nid ($(mkClosure 'slave) us)

  -- Distribute 1 .. n amongst the slave processes 
  spawnLocal $ forM_ (zip [1 .. n] (cycle slaveProcesses)) $ 
    \(m, them) -> send them m 

  -- Wait for the result
  sumIntegers (fromIntegral n)
