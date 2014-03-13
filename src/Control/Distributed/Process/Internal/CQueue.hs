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
  ) where

import Prelude hiding (length, reverse)
import Control.Concurrent.STM
  ( atomically
  , STM
  , TChan
  , tryReadTChan
  , newTChan
  , writeTChan
  , readTChan
  , orElse
  , retry
  )
import Control.Applicative ((<$>), (<*>))
import Control.Exception (mask_, onException)
import System.Timeout (timeout)
import Control.Distributed.Process.Internal.StrictMVar
  ( StrictMVar(StrictMVar)
  , newMVar
  , takeMVar
  , putMVar
  )
import Control.Distributed.Process.Internal.StrictList
  ( StrictList(..)
  , append
  )
import Data.Maybe (fromJust)
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

-- | Variant of enqueue for use in the STM monad.
enqueueSTM :: CQueue a -> a -> STM ()
enqueueSTM (CQueue _arrived incoming) !a = writeTChan incoming a

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
        -> IO (Maybe a)      -- ^ 'Nothing' only on timeout
dequeue (CQueue arrived incoming) blockSpec matchons =
  case blockSpec of
    Timeout n -> timeout n $ fmap fromJust run
    _other    ->
       case chunks of
         [Right ports] -> -- channels only, this is easy:
           case blockSpec of
             NonBlocking -> atomically $ waitChans ports (return Nothing)
             _           -> atomically $ waitChans ports retry
                              -- no onException needed
         _other -> run
  where
    chunks = chunkMatches matchons

    run = mask_ $ do
           arr <- takeMVar arrived
           let grabNew xs = do
                 r <- atomically $ tryReadTChan incoming
                 case r of
                   Nothing -> return xs
                   Just x  -> grabNew (Snoc xs x)
           arr' <- grabNew arr
           goCheck chunks arr'

    waitChans ports on_block =
        foldr orElse on_block (map (fmap Just) ports)

    --
    -- First check the MatchChunks against the messages already in the
    -- mailbox.  For channel matches, we do a non-blocking check at
    -- this point.
    --
    goCheck :: MatchChunks m a
            -> StrictList m  -- messages to check, in this order
            -> IO (Maybe a)

    goCheck [] old = goWait old

    goCheck (Right ports : rest) old = do
      r <- atomically $ waitChans ports (return Nothing) -- does not block
      case r of
        Just _  -> returnOld old r
        Nothing -> goCheck rest old

    goCheck (Left matches : rest) old = do
           -- checkArrived might in principle take arbitrary time, so
           -- we ought to call restore and use an exception handler.  However,
           -- the check is usually fast (just a comparison), and the overhead
           -- of passing around restore and setting up exception handlers is
           -- high.  So just don't use expensive matchIfs!
      case checkArrived matches old of
        (old', Just r)  -> returnOld old' (Just r)
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

    waitIncoming :: IO (Maybe (Either m a))
    waitIncoming = case blockSpec of
      NonBlocking -> atomically $ fmap Just stm `orElse` return Nothing
      _           -> atomically $ fmap Just stm
     where
      stm = mkSTM chunks

    --
    -- The initial pass didn't find a message, so now we go into blocking
    -- mode.
    --
    -- Contents of 'arrived' from now on is (old ++ new), and
    -- messages that arrive are snocced onto new.
    --
    goWait old = do
      r <- waitIncoming `onException` putMVar arrived old
      case r of
        --  Nothing => non-blocking and no message
        Nothing -> returnOld old Nothing
        Just e  -> case e of
          --
          -- Left => message arrived in the process mailbox.  We now have to
          -- run through the MatchChunks checking each one, because we might
          -- have a situation where the first chunk fails to match and the
          -- second chunk is a channel match and there *is* a message in the
          -- channel.  In that case the channel wins.
          --
          Left m -> goCheck1 chunks m old
          --
          -- Right => message arrived on a channel first
          --
          Right a -> returnOld old (Just a)

    --
    -- A message arrived in the process inbox; check the MatchChunks for
    -- a valid match.
    --
    goCheck1 :: MatchChunks m a
             -> m               -- single message to check
             -> StrictList m    -- old messages we have already checked
             -> IO (Maybe a)

    goCheck1 [] m old = goWait (Snoc old m)

    goCheck1 (Right ports : rest) m old = do
      r <- atomically $ waitChans ports (return Nothing) -- does not block
      case r of
        Nothing -> goCheck1 rest m old
        Just _  -> returnOld (Snoc old m) r

    goCheck1 (Left matches : rest) m old = do
      case checkMatches matches m of
        Nothing -> goCheck1 rest m old
        Just p  -> returnOld old (Just p)

    -- a common pattern for putting back the arrived queue at the end
    returnOld :: StrictList m -> Maybe a -> IO (Maybe a)
    returnOld old r = do putMVar arrived old; return r

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
mkWeakCQueue m@(CQueue (StrictMVar (MVar m#)) _) f = IO $ \s ->
  case mkWeak# m# m f s of (# s1, w #) -> (# s1, Weak w #)
