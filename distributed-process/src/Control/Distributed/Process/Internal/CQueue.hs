-- | Concurrent queue for single reader, single writer
{-# LANGUAGE MagicHash, UnboxedTuples #-}
module Control.Distributed.Process.Internal.CQueue 
  ( CQueue
  , BlockSpec(..)
  , newCQueue
  , enqueue
  , dequeue
  , mkWeakCQueue
  ) where

import Prelude hiding (length, reverse)
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
import Control.Distributed.Process.Internal.StrictMVar 
  ( StrictMVar(StrictMVar)
  , newMVar
  , takeMVar
  , putMVar
  )
import Control.Distributed.Process.Internal.StrictList
  ( StrictList(..)
  , reverse
  , reverse'
  )
import GHC.MVar (MVar(MVar))
import GHC.IO (IO(IO)) 
import GHC.Prim (mkWeak#)
import GHC.Weak (Weak(Weak))

-- We use a TCHan rather than a Chan so that we have a non-blocking read
data CQueue a = CQueue (StrictMVar (StrictList a)) -- Arrived
                       (TChan a)                   -- Incoming

newCQueue :: IO (CQueue a)
newCQueue = CQueue <$> newMVar Nil <*> atomically newTChan

-- | Enqueue an element
--
-- Enqueue is strict.
enqueue :: CQueue a -> a -> IO ()
enqueue (CQueue _arrived incoming) !a = atomically $ writeTChan incoming a 

data BlockSpec = 
    NonBlocking
  | Blocking
  | Timeout Int

-- | Dequeue an element
--
-- The timeout (if any) is applied only to waiting for incoming messages, not
-- to checking messages that have already arrived
dequeue :: forall a b. 
           CQueue a          -- ^ Queue
        -> BlockSpec         -- ^ Blocking behaviour 
        -> [a -> Maybe b]    -- ^ List of matches
        -> IO (Maybe b)      -- ^ 'Nothing' only on timeout
dequeue (CQueue arrived incoming) blockSpec matches = go 
  where    
    go :: IO (Maybe b)
    go = mask $ \restore -> do
      arr <- takeMVar arrived 
      -- We first check the arrived messages. If we get interrupted during this
      -- search, we just put the MVar back (we haven't read from the Chan yet)
      (arr', mb) <- onException (restore (checkArrived Nil arr))
                                (putMVar arrived arr) 
      case (mb, blockSpec) of
        (Just b, _) -> do 
          putMVar arrived arr'
          return (Just b)
        (Nothing, NonBlocking) ->
          checkNonBlocking arr'
        (Nothing, Blocking) ->
          Just <$> checkBlocking arr' 
        (Nothing, Timeout n) ->
          timeout n $ checkBlocking arr'

    -- We reverse the accumulator on return only if we find a match
    checkArrived :: StrictList a -> StrictList a -> IO (StrictList a, Maybe b)
    checkArrived acc Nil = return (acc, Nothing)
    checkArrived acc (Cons x xs) = 
      case check x of
        Just y  -> return (reverse' acc xs, Just y)
        Nothing -> checkArrived (Cons x acc) xs

    -- If we call checkBlocking there may or may not be a timeout
    checkBlocking :: StrictList a -> IO b
    checkBlocking acc = do
      -- readTChan is a blocking call, and hence is interruptable. If it is 
      -- interrupted, we put the value of the accumulator in 'arrived'  
      -- (as opposed to the original value), so that no messages get lost
      -- (hence the low-level structure using mask rather than modifyMVar)
      x <- onException (atomically $ readTChan incoming)
                       (putMVar arrived $ reverse acc)
      case check x of
        Nothing -> checkBlocking (Cons x acc)
        Just y  -> putMVar arrived (reverse acc) >> return y 

    -- checkNonBlocking is only called if there is no timeout
    checkNonBlocking :: StrictList a -> IO (Maybe b)
    checkNonBlocking acc = do
      -- tryReadTChan is *not* interruptible
      mx <- atomically $ tryReadTChan incoming
      case mx of
        Nothing -> putMVar arrived (reverse acc) >> return Nothing
        Just x  -> case check x of
          Nothing -> checkNonBlocking (Cons x acc)
          Just y  -> putMVar arrived (reverse acc) >> return (Just y)
        
    check :: a -> Maybe b
    check = checkMatches matches 

    checkMatches :: [a -> Maybe b] -> a -> Maybe b
    checkMatches []     _ = Nothing
    checkMatches (m:ms) a = case m a of Nothing -> checkMatches ms a
                                        Just b  -> Just b

-- | Weak reference to a CQueue
mkWeakCQueue :: CQueue a -> IO () -> IO (Weak (CQueue a))
mkWeakCQueue m@(CQueue (StrictMVar (MVar m#)) _) f = IO $ \s ->
  case mkWeak# m# m f s of (# s1, w #) -> (# s1, Weak w #)
