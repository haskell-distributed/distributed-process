-- | Concurrent queue for single reader, single writer
module Control.Distributed.Process.Internal.CQueue 
  ( CQueue
  , BlockSpec(..)
  , newCQueue
  , enqueue
  , dequeue
  ) where

import Control.Monad (join)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar)
import Control.Concurrent.STM 
  ( atomically
  , TChan
  , newTChan
  , writeTChan
  , readTChan
  , tryReadTChan
  )
import Control.Applicative ((<$>), (<*>))
import Control.Exception (mask, onException)
import System.Timeout (timeout)

-- TODO: The only reason for TChan rather than Chan here is to that we have
-- a non-blocking read
data CQueue a = CQueue (MVar [a]) -- Arrived
                       (TChan a)  -- Incoming

newCQueue :: IO (CQueue a)
newCQueue = CQueue <$> newMVar [] <*> atomically newTChan

enqueue :: CQueue a -> a -> IO ()
enqueue (CQueue _arrived incoming) a = atomically $ writeTChan incoming a 

data BlockSpec = 
    NonBlocking
  | Blocking
  | Timeout Int

dequeue :: forall a b. 
           CQueue a          -- ^ Queue
        -> BlockSpec -- ^ Blocking behaviour 
        -> [a -> Maybe b]    -- ^ List of matches
        -> IO (Maybe b)      -- ^ 'Nothing' only on timeout
dequeue (CQueue arrived incoming) blockSpec matches = 
  case blockSpec of
    Timeout t -> join <$> timeout t go
    _         -> go
  where    
    go :: IO (Maybe b)
    go = mask $ \restore -> do
      arr <- takeMVar arrived 
      -- We first check the arrived messages. If we timeout during this search,
      -- we just put the MVar back (we haven't touched the Chan yet)
      (arr', mb) <- onException (restore (checkArrived [] arr))
                                (putMVar arrived arr) 
      case (mb, blockSpec) of
        (Just b, _) -> do 
          putMVar arrived arr'
          return (Just b)
        (Nothing, NonBlocking) ->
          checkNonBlocking arr'
        (Nothing, _) ->
          Just <$> checkBlocking arr' 

    -- We reverse the accumulator on return only if we find a match
    checkArrived :: [a] -> [a] -> IO ([a], Maybe b)
    checkArrived acc []     = return (acc, Nothing)
    checkArrived acc (x:xs) = 
      case check x of
        Just y  -> return (reverse acc ++ xs, Just y)
        Nothing -> checkArrived (x:acc) xs

    -- If we call checkBlocking there may or may not be a timeout
    checkBlocking :: [a] -> IO b
    checkBlocking acc = do
      -- readTChan is a blocking call, and hence is interruptable. If it is 
      -- interrupted, we put the value of the accumulator in 'arrived'  
      -- (as opposed to the original value), so that no messages get lost
      -- (hence the low-level structure using mask rather than modifyMVar)
      x <- onException (atomically $ readTChan incoming)
                       (putMVar arrived $ reverse acc)
      case check x of
        Nothing -> checkBlocking (x:acc)
        Just y  -> putMVar arrived (reverse acc) >> return y 

    -- checkNonBlocking is only called if there is no timeout
    checkNonBlocking :: [a] -> IO (Maybe b)
    checkNonBlocking acc = do
      -- tryReadTChan is *not* interruptible
      mx <- atomically $ tryReadTChan incoming
      case mx of
        Nothing -> putMVar arrived (reverse acc) >> return Nothing
        Just x  -> case check x of
          Nothing -> checkNonBlocking (x:acc)
          Just y  -> putMVar arrived (reverse acc) >> return (Just y)
        
    check :: a -> Maybe b
    check = checkMatches matches 

    checkMatches :: [a -> Maybe b] -> a -> Maybe b
    checkMatches []     _ = Nothing
    checkMatches (m:ms) a = case m a of Nothing -> checkMatches ms a
                                        Just b  -> Just b
