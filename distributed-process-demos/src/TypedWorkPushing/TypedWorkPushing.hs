module TypedWorkPushing where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import PrimeFactors

slave :: SendPort Integer -> ReceivePort Integer -> Process ()
slave results todo = forever $ do
  n <- receiveChan todo 
  sendChan results (numPrimeFactors n)

sdictInteger :: SerializableDict Integer
sdictInteger = SerializableDict

remotable ['slave, 'sdictInteger]

-- | Wait for n integers and sum them all up
sumIntegers :: ReceivePort Integer -> Int -> Process Integer
sumIntegers rport = go 0
  where
    go :: Integer -> Int -> Process Integer
    go !acc 0 = return acc
    go !acc n = do
      m <- receiveChan rport 
      go (acc + m) (n - 1)

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  (sport, rport) <- newChan

  -- Start slave processes 
  slaveProcesses <- forM slaves $ \nid -> 
    spawnChannel $(mkStatic 'sdictInteger) nid ($(mkClosure 'slave) sport)

  -- Distribute 1 .. n amongst the slave processes 
  spawnLocal $ forM_ (zip [1 .. n] (cycle slaveProcesses)) $ 
    \(m, them) -> sendChan them m 

  -- Wait for the result
  sumIntegers rport (fromIntegral n)
