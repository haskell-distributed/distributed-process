-- | Concurrent queue for single reader, single writer
module Control.Distributed.Process.Internal.CQueue 
  ( CQueue
  , newCQueue
  , enqueue
  , dequeue
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

dequeue :: forall a b. 
           CQueue a        -- ^ Queue
        -> Maybe Int       -- ^ Timeout
        -> [a -> Maybe b]  -- ^ List of matches
        -> IO (Maybe b)    -- ^ Nothing only on timeout
dequeue (CQueue arrived incoming) mTimeout matches = 
    modifyMVar arrived (checkArrived [])
  where
    checkArrived :: [a] -> [a] -> IO ([a], Maybe b)
    checkArrived acc (x:xs) = 
      case check x of
        Just y  -> return (reverse acc ++ xs, Just y)
        Nothing -> checkArrived (x:acc) xs
    checkArrived acc [] = do
      result <- case mTimeout of
        Nothing -> Just      <$> checkIncoming acc 
        Just t  -> timeout t  $  checkIncoming acc 
      case result of
        Nothing        -> return (reverse acc, Nothing)
        Just (acc', b) -> return (reverse acc', Just b)

    checkIncoming :: [a] -> IO ([a], b)
    checkIncoming acc = do
      x <- readChan incoming
      case check x of
        Just y  -> return (acc, y)
        Nothing -> checkIncoming (x:acc)

    check :: a -> Maybe b
    check = checkMatches matches 

    checkMatches :: [a -> Maybe b] -> a -> Maybe b
    checkMatches []     _ = Nothing
    checkMatches (m:ms) a = case m a of Nothing -> checkMatches ms a
                                        Just b  -> Just b
