{-# LANGUAGE NoImplicitPrelude #-}
module Control.Distributed.Process.Extras.Internal.Queue.SeqQ
  ( SeqQ
  , empty
  , isEmpty
  , singleton
  , enqueue
  , dequeue
  , peek
  , filter
  , size
  )
  where

-- A simple FIFO queue implementation backed by @Data.Sequence@.
import Prelude hiding (filter, length)
import Data.Sequence
  ( Seq
  , ViewR(..)
  , (<|)
  , viewr
  , length
  )
import qualified Data.Sequence as Seq (empty, singleton, null, filter)

newtype SeqQ a = SeqQ { q :: Seq a }
  deriving (Show)

instance Eq a => Eq (SeqQ a) where
  a == b = (q a) == (q b)

{-# INLINE empty #-}
empty :: SeqQ a
empty = SeqQ Seq.empty

isEmpty :: SeqQ a -> Bool
isEmpty = Seq.null . q

{-# INLINE singleton #-}
singleton :: a -> SeqQ a
singleton = SeqQ . Seq.singleton

{-# INLINE enqueue #-}
enqueue :: SeqQ a -> a -> SeqQ a
enqueue s a = SeqQ $ a <| q s

{-# INLINE dequeue #-}
dequeue :: SeqQ a -> Maybe (a, SeqQ a)
dequeue s = maybe Nothing (\(s' :> a) -> Just (a, SeqQ s')) $ getR s

{-# INLINE peek #-}
peek :: SeqQ a -> Maybe a
peek s = maybe Nothing (\(_ :> a) -> Just a) $ getR s

{-# INLINE size #-}
size :: SeqQ a -> Int
size = length . q

filter :: (a -> Bool) -> SeqQ a -> SeqQ a
filter c s = SeqQ $ Seq.filter c (q s)

getR :: SeqQ a -> Maybe (ViewR a)
getR s =
  case (viewr (q s)) of
    EmptyR -> Nothing
    a      -> Just a
