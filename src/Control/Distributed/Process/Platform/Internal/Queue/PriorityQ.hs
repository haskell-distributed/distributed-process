{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE StandaloneDeriving #-}
module Control.Distributed.Process.Platform.Internal.Queue.PriorityQ where

-- NB: we might try this with a skewed binomial heap at some point,
-- but for now, we'll use this module from the fingertree package
import qualified Data.PriorityQueue.FingerTree as PQ
import Data.PriorityQueue.FingerTree (PQueue)

newtype PriorityQ k a = PriorityQ { q :: PQueue k a }

{-# INLINE empty #-}
empty :: Ord k => PriorityQ k v
empty = PriorityQ $ PQ.empty

{-# INLINE isEmpty #-}
isEmpty :: Ord k => PriorityQ k v -> Bool
isEmpty = PQ.null . q

{-# INLINE singleton #-}
singleton :: Ord k => k -> a -> PriorityQ k a
singleton !k !v = PriorityQ $ PQ.singleton k v

{-# INLINE enqueue #-}
enqueue :: Ord k => k -> v -> PriorityQ k v -> PriorityQ k v
enqueue !k !v p = PriorityQ (PQ.add k v $ q p)

{-# INLINE dequeue #-}
dequeue :: Ord k => PriorityQ k v -> Maybe (v, PriorityQ k v)
dequeue p = maybe Nothing (\(v, pq') -> Just (v, pq')) $
              case (PQ.minView (q p)) of
                Nothing     -> Nothing
                Just (v, q') -> Just (v, PriorityQ $ q')

{-# INLINE peek #-}
peek :: Ord k => PriorityQ k v -> Maybe v
peek p = maybe Nothing (\(v, _) -> Just v) $ dequeue p

