module WorkStealing where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure

fib :: Integer -> Integer
fib = go (0, 1)
  where
    go (!a, !b) !n | n == 0    = a
                   | otherwise = go (b, a + b) (n - 1)

slave :: ProcessId -> Process ()
slave workQueue = do
    us <- getSelfPid
    go us
  where
    go us = do
      -- Ask the queue for work 
      send workQueue us
   
      -- Wait for a reply
      mWork <- receiveWait 
        [ match $ \(pid, n) -> return $ Just (pid, n)
        , match $ \() -> return Nothing
        ]

      -- If there is work, do it and repeat; otherwise, exit
      case mWork of
        Just (pid, n) -> send pid (fib n) >> go us
        Nothing       -> return ()

remotable ['slave]

master :: Integer -> [NodeId] -> Process Integer
master n slaves = do
  us <- getSelfPid

  workQueue <- spawnLocal $ do
    -- As long as there is work, return the next Fib to compute
    forM_ [1 .. n] $ \m -> do
      them <- expect 
      send them (us, m)

    -- After that, just report that the work is done
    forever $ do
      pid <- expect
      send pid ()

  -- Start processes on the slaves that compute Fibonacci numbers
  forM_ slaves $ flip spawn ($(mkClosure 'slave) workQueue)

  -- Wait for the result
  partials <- replicateM (fromInteger n) (expect :: Process Integer)

  -- And return the sum
  return (sum partials) 
