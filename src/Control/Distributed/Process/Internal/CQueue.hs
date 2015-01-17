{-# LANGUAGE BangPatterns  #-}
{-# LANGUAGE MagicHash, UnboxedTuples, PatternGuards, ScopedTypeVariables, RankNTypes #-}
-- | Concurrent queue for single reader, single writer
module Control.Distributed.Process.Internal.CQueue
  ( CQueue
  , BlockSpec(..)
  , MatchOn(..)
  , newCQueue
  , enqueue
  , enqueueSTM
  , dequeue
  , mkWeakCQueue
  , queueSize 
  ) where

import Prelude hiding (length, reverse)
import Control.Concurrent.STM
  ( atomically
  , check
  , STM
  , TChan
  , TVar
  , modifyTVar'
  , writeTVar
  , tryReadTChan
  , newTChan
  , newTVarIO
  , writeTChan
  , readTChan
  , readTVar
  , readTVarIO
  , orElse
  , retry
  , registerDelay
  )
import Control.Applicative ((<$>), (<*>))
import Control.Monad (when)
import Control.Distributed.Process.Internal.StrictList
  ( StrictList(..)
  , append
  )
import Data.Maybe (isJust)
import GHC.IO (IO(IO))
import GHC.Prim (mkWeak#)
import GHC.Conc (TVar(TVar))
import GHC.Weak (Weak(Weak))

-- We use a TCHan rather than a Chan so that we have a non-blocking read
data CQueue a = CQueue (TVar (StrictList a)) -- Arrived
                       (TChan a)             -- Incoming
                       (TVar Int)            -- Queue size

newCQueue :: IO (CQueue a)
newCQueue = CQueue <$> newTVarIO Nil <*> atomically newTChan <*> newTVarIO 0

-- | Enqueue an element
--
-- Enqueue is strict.
enqueue :: CQueue a -> a -> IO ()
enqueue c !a = atomically (enqueueSTM c a)

-- | Variant of enqueue for use in the STM monad.
enqueueSTM :: CQueue a -> a -> STM ()
enqueueSTM (CQueue _arrived incoming size) !a = do
   writeTChan incoming a
   modifyTVar' size succ

data BlockSpec =
    NonBlocking
  | Blocking
  | Timeout Int

data MatchOn m a
 = MatchMsg  (m -> Maybe a)
 | MatchChan (STM a)

type MatchChunks m a = [Either [m -> Maybe a] [STM a]]

chunkMatches :: [MatchOn m a] -> MatchChunks m a
chunkMatches [] = []
chunkMatches (MatchMsg m : ms) = Left (m : chk) : chunkMatches rest
   where (chk, rest) = spanMatchMsg ms
chunkMatches (MatchChan r : ms) = Right (r : chk) : chunkMatches rest
   where (chk, rest) = spanMatchChan ms

spanMatchMsg :: [MatchOn m a] -> ([m -> Maybe a], [MatchOn m a])
spanMatchMsg [] = ([],[])
spanMatchMsg (m : ms)
    | MatchMsg msg <- m = (msg:msgs, rest)
    | otherwise         = ([], m:ms)
    where !(msgs,rest) = spanMatchMsg ms

spanMatchChan :: [MatchOn m a] -> ([STM a], [MatchOn m a])
spanMatchChan [] = ([],[])
spanMatchChan (m : ms)
    | MatchChan stm <- m = (stm:stms, rest)
    | otherwise          = ([], m:ms)
    where !(stms,rest)  = spanMatchChan ms

-- | Dequeue an element
--
-- The timeout (if any) is applied only to waiting for incoming messages, not
-- to checking messages that have already arrived
dequeue :: forall m a.
           CQueue m          -- ^ Queue
        -> BlockSpec         -- ^ Blocking behaviour
        -> [MatchOn m a]     -- ^ List of matches
        -> IO (Maybe a)      -- ^ Nothing' only on timeout
dequeue (CQueue arrived incoming size) blockSpec matchons =
  case blockSpec of
    Timeout n -> registerDelay n >>= run
    _other    ->
       case chunks of
         [Right ports] -> -- channels only, this is easy:
           case blockSpec of
             NonBlocking -> atomically $ decrementJust $ waitChans ports (return Nothing)
             _           -> atomically $ decrementJust $ waitChans ports retry
                              -- no onException needed
         _other -> newTVarIO False >>= run
  where
    chunks = chunkMatches matchons

    decrementJust f = do
      mx <- f
      when (isJust mx) (modifyTVar' size pred)
      return mx

    waitChans ports on_block =
        foldr orElse on_block (map (fmap Just) ports)

    run :: TVar Bool -> IO (Maybe a)
    run tm = do
        -- We need to wait on both ports and mailbox, here we want
        -- to break a transaction into multiple ones in order to
        -- reduce number of retries. Transaction are split into
        -- parts that are safe to use in concurrent enviroment in
        -- presence of asynchonous exceptions.
         
        -- 1st transaction read consume all values from the input 
        -- stream. Having this transaction guarantees that all the
        -- rest computation will not be rolled back if a new value
        -- will enter the chan.
        let loop = do
              r <- tryReadTChan incoming
              case r of
                Nothing -> return ()
                Just x  -> do modifyTVar' arrived (flip Snoc x)
                              loop
        atomically $ loop

        -- 2nd transaction, find matched values in arrived, and
	-- match new values.
        atomically $ do
           mr <- goCheck chunks =<< readTVar arrived
           decrementJust $ maybe ((const Nothing <$> (readTVar tm >>= check))
                                     `orElse` goWait)
                                 (return . Just) mr

    --
    -- First check the MatchChunks against the messages already in the
    -- mailbox.  For channel matches, we do a non-blocking check at
    -- this point.
    --
    goCheck :: MatchChunks m a
            -> StrictList m  -- messages to check, in this order
            -> STM (Maybe a)

    goCheck [] _ = return Nothing 

    goCheck (Right ports : rest) old = do
      r <- waitChans ports (return Nothing) -- does not block
      case r of
        Just _  -> return r
        Nothing -> goCheck rest old

    goCheck (Left matches : rest) old = do
           -- checkArrived might in principle take arbitrary time, so
           -- we ought to call restore and use an exception handler.  However,
           -- the check is usually fast (just a comparison), and the overhead
           -- of passing around restore and setting up exception handlers is
           -- high.  So just don't use expensive matchIfs!
      case checkArrived matches old of
        (old', Just r)  -> writeTVar arrived old' >> return (Just r)
        (old', Nothing) -> goCheck rest old'
          -- use the result list, which is now left-biased

    --
    -- Construct an STM transaction that looks at the relevant channels
    -- in the correct order.
    --
    mkSTM :: MatchChunks m a -> STM (Either m a)
    mkSTM [] = retry
    mkSTM (Left _ : rest)
      = fmap Left (readTChan incoming) `orElse` mkSTM rest
    mkSTM (Right ports : rest)
      = foldr orElse (mkSTM rest) (map (fmap Right) ports)

    waitIncoming :: STM (Maybe (Either m a))
    waitIncoming = case blockSpec of
      NonBlocking -> fmap Just stm `orElse` return Nothing
      _           -> fmap Just stm
     where
      stm = mkSTM chunks

    --
    -- The initial pass didn't find a message, so now we go into blocking
    -- mode.
    --
    -- Contents of 'arrived' from now on is (old ++ new), and
    -- messages that arrive are snocced onto new.
    --
    goWait :: STM (Maybe a)
    goWait = do
      r <- waitIncoming
      case r of
        --  Nothing => non-blocking and no message
        Nothing -> return Nothing
        Just e  -> case e of
          --
          -- Left => message arrived in the process mailbox.  We now have to
          -- run through the MatchChunks checking each one, because we might
          -- have a situation where the first chunk fails to match and the
          -- second chunk is a channel match and there *is* a message in the
          -- channel.  In that case the channel wins.
          --
          Left m -> goCheck1 chunks m
          --
          -- Right => message arrived on a channel first
          --
          Right a -> return (Just a)

    --
    -- A message arrived in the process inbox; check the MatchChunks for
    -- a valid match.
    --
    goCheck1 :: MatchChunks m a
             -> m               -- single message to check
             -> STM (Maybe a)

    goCheck1 [] m = modifyTVar' arrived (flip Snoc m) >> goWait

    goCheck1 (Right ports : rest) m = do
      r <- waitChans ports (return Nothing) -- does not block
      case r of
        Nothing -> goCheck1 rest m
        Just _  -> modifyTVar' arrived (flip Snoc m) >> return r

    goCheck1 (Left matches : rest) m = do
      case checkMatches matches m of
        Nothing -> goCheck1 rest m
        Just p  -> return (Just p)

    -- as a side-effect, this left-biases the list
    checkArrived :: [m -> Maybe a] -> StrictList m -> (StrictList m, Maybe a)
    checkArrived matches list = go list Nil
      where
        go Nil Nil           = (Nil, Nothing)
        go Nil r             = go r Nil
        go (Append xs ys) tl = go xs (append ys tl)
        go (Snoc xs x)    tl = go xs (Cons x tl)
        go (Cons x xs)    tl
          | Just y <- checkMatches matches x = (append xs tl, Just y)
          | otherwise = let !(rest,r) = go xs tl in (Cons x rest, r)

    checkMatches :: [m -> Maybe a] -> m -> Maybe a
    checkMatches []     _ = Nothing
    checkMatches (m:ms) a = case m a of Nothing -> checkMatches ms a
                                        Just b  -> Just b

-- | Weak reference to a CQueue
mkWeakCQueue :: CQueue a -> IO () -> IO (Weak (CQueue a))
mkWeakCQueue m@(CQueue (TVar m#) _ _) f = IO $ \s ->
  case mkWeak# m# m f s of (# s1, w #) -> (# s1, Weak w #)

queueSize :: CQueue a -> IO Int
queueSize (CQueue _ _ size) = readTVarIO size
