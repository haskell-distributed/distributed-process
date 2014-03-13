{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE MagicHash, UnboxedTuples #-}
-- | Clone of Control.Concurrent.STM.TQueue with support for mkWeakTQueue
--
-- Not all functionality from the original module is available: unGetTQueue,
-- peekTQueue and tryPeekTQueue are missing. In order to implement these we'd
-- need to be able to touch# the write end of the queue inside unGetTQueue, but
-- that means we need a version of touch# that works within the STM monad.
module Control.Distributed.Process.Internal.WeakTQueue (
  -- * Original functionality
  TQueue,
  newTQueue,
  newTQueueIO,
  readTQueue,
  tryReadTQueue,
  writeTQueue,
  isEmptyTQueue,
  -- * New functionality
  mkWeakTQueue
  ) where

import Prelude hiding (read)
import GHC.Conc
import Data.Typeable (Typeable)
import GHC.IO (IO(IO))
import GHC.Prim (mkWeak#)
import GHC.Weak (Weak(Weak))

--------------------------------------------------------------------------------
-- Original functionality                                                     --
--------------------------------------------------------------------------------

-- | 'TQueue' is an abstract type representing an unbounded FIFO channel.
data TQueue a = TQueue {-# UNPACK #-} !(TVar [a])
                       {-# UNPACK #-} !(TVar [a])
  deriving Typeable

instance Eq (TQueue a) where
  TQueue a _ == TQueue b _ = a == b

-- |Build and returns a new instance of 'TQueue'
newTQueue :: STM (TQueue a)
newTQueue = do
  read  <- newTVar []
  write <- newTVar []
  return (TQueue read write)

-- |@IO@ version of 'newTQueue'.  This is useful for creating top-level
-- 'TQueue's using 'System.IO.Unsafe.unsafePerformIO', because using
-- 'atomically' inside 'System.IO.Unsafe.unsafePerformIO' isn't
-- possible.
newTQueueIO :: IO (TQueue a)
newTQueueIO = do
  read  <- newTVarIO []
  write <- newTVarIO []
  return (TQueue read write)

-- |Write a value to a 'TQueue'.
writeTQueue :: TQueue a -> a -> STM ()
writeTQueue (TQueue _read write) a = do
  listend <- readTVar write
  writeTVar write (a:listend)

-- |Read the next value from the 'TQueue'.
readTQueue :: TQueue a -> STM a
readTQueue (TQueue read write) = do
  xs <- readTVar read
  case xs of
    (x:xs') -> do writeTVar read xs'
                  return x
    [] -> do ys <- readTVar write
             case ys of
               [] -> retry
               _  -> case reverse ys of
                       [] -> error "readTQueue"
                       (z:zs) -> do writeTVar write []
                                    writeTVar read zs
                                    return z

-- | A version of 'readTQueue' which does not retry. Instead it
-- returns @Nothing@ if no value is available.
tryReadTQueue :: TQueue a -> STM (Maybe a)
tryReadTQueue c = fmap Just (readTQueue c) `orElse` return Nothing

-- |Returns 'True' if the supplied 'TQueue' is empty.
isEmptyTQueue :: TQueue a -> STM Bool
isEmptyTQueue (TQueue read write) = do
  xs <- readTVar read
  case xs of
    (_:_) -> return False
    [] -> do ys <- readTVar write
             case ys of
               [] -> return True
               _  -> return False

--------------------------------------------------------------------------------
-- New functionality                                                          --
--------------------------------------------------------------------------------

mkWeakTQueue :: TQueue a -> IO () -> IO (Weak (TQueue a))
mkWeakTQueue q@(TQueue _read (TVar write#)) f = IO $ \s ->
  case mkWeak# write# q f s of (# s', w #) -> (# s', Weak w #)
