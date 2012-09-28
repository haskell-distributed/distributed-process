module WorkStealing where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import PrimeFactors

slave :: (ProcessId, ProcessId) -> Process ()
slave (master, workQueue) = do
    us <- getSelfPid
    go us
  where
    go us = do
      -- Ask the queue for work 
      send workQueue us
   
      -- If there is work, do it, otherwise terminate 
      receiveWait 
        [ match $ \n  -> send master (numPrimeFactors n) >> go us
        , match $ \() -> return ()
        ]

remotable ['slave]

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  us <- getSelfPid

  workQueue <- spawnLocal $ do
    -- Reply with the next bit of work to be done 
    forM_ [1 .. n] $ \m -> do
      them <- expect 
      send them m 

    -- Once all the work is done, tell the slaves to terminate
    forever $ do
      pid <- expect
      send pid ()

  -- Start slave processes 
  forM_ slaves $ \nid -> spawn nid ($(mkClosure 'slave) (us, workQueue))

  -- Wait for the result
  partials <- replicateM (fromIntegral n) (expect :: Process Integer)

  -- And return the sum
  return (sum partials) 
