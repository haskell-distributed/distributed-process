-- | Concurrent queue for single reader, single writer
module Control.Distributed.Process.Internal.CQueue 
  ( CQueue
  , newCQueue
  , enqueue
  , dequeueMatching
  ) where

import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Control.Concurrent.Chan (Chan, newChan, writeChan, readChan)

data CQueue a = CQueue (MVar [a]) -- arrived
                       (Chan a)   -- incoming

newCQueue :: IO (CQueue a)
newCQueue = do
  arrived   <- newMVar []
  incoming <- newChan
  return (CQueue arrived incoming)

enqueue :: CQueue a -> a -> IO ()
enqueue (CQueue _arrived incoming) = writeChan incoming

dequeueMatching :: forall a. CQueue a -> (a -> Bool) -> IO a
dequeueMatching (CQueue arrived incoming) matches =
    modifyMVar arrived (checkArrived [])
  where
    checkArrived :: [a] -> [a] -> IO ([a], a)
    checkArrived xs' []     = checkIncoming xs'
    checkArrived xs' (x:xs)
                | matches x = return (reverse xs' ++ xs, x)
                | otherwise = checkArrived (x:xs') xs

    checkIncoming :: [a] -> IO ([a], a)
    checkIncoming xs' = do
      x <- readChan incoming
      if matches x
        then return (reverse xs', x)
        else checkIncoming (x:xs')
