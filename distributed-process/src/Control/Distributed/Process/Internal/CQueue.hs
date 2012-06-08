-- | Concurrent queue for single reader, single writer
module Control.Distributed.Process.Internal.CQueue 
  ( CQueue
  , newCQueue
  , enqueue
  , dequeueMatching
  ) where

import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Control.Concurrent.Chan (Chan, newChan, writeChan, readChan)
import Control.Applicative ((<$>))
import System.Timeout (timeout)

data CQueue a = CQueue (MVar [a]) -- arrived
                       (Chan a)   -- incoming

newCQueue :: IO (CQueue a)
newCQueue = do
  arrived   <- newMVar []
  incoming <- newChan
  return (CQueue arrived incoming)

enqueue :: CQueue a -> a -> IO ()
enqueue (CQueue _arrived incoming) = writeChan incoming

-- TODO: subtract the timeout value if a non-matching messages arrives
dequeueMatching :: forall a. 
                   CQueue a 
                -> Maybe Int 
                -> (a -> Bool) 
                -> IO (Maybe a)
dequeueMatching (CQueue arrived incoming) mTimeout matches =
    modifyMVar arrived (checkArrived [])
  where
    checkArrived :: [a] -> [a] -> IO ([a], Maybe a)
    checkArrived xs' []     = checkIncoming xs'
    checkArrived xs' (x:xs)
                | matches x = return (reverse xs' ++ xs, Just x)
                | otherwise = checkArrived (x:xs') xs

    checkIncoming :: [a] -> IO ([a], Maybe a)
    checkIncoming xs' = do
      mx <- case mTimeout of 
        Just 0  -> return Nothing
        Just n  -> timeout n $ readChan incoming
        Nothing -> Just <$> readChan incoming
      case mx of
        Nothing -> return (reverse xs', Nothing)
        Just x 
          | matches x -> return (reverse xs', Just x)
          | otherwise -> checkIncoming (x:xs')
