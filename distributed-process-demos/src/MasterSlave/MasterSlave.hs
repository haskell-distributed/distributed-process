module MasterSlave where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import PrimeFactors

slave :: (ProcessId, Integer) -> Process ()
slave (pid, n) = send pid (numPrimeFactors n)

remotable ['slave]

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  us <- getSelfPid

  -- Distribute 1 .. n amongst the slave processes 
  forM_ (zip [1 .. n] (cycle slaves)) $ \(m, them) -> 
    spawn them ($(mkClosure 'slave) (us, m))

  -- Wait for the result
  partials <- replicateM (fromIntegral n) (expect :: Process Integer)

  -- And return the sum
  return (sum partials) 
