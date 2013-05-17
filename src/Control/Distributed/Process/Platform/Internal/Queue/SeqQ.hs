-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Internal.Queue.SeqQ
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
--
-- A simple FIFO queue implementation backed by @Data.Sequence@.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Internal.Queue.SeqQ
  ( SeqQ
  , empty
  , isEmpty
  , singleton
  , enqueue
  , dequeue
  , peek
  )
  where

import Data.Sequence
  ( Seq
  , ViewR(..)
  , (<|)
  , viewr
  )
import qualified Data.Sequence as Seq (empty, singleton, null)

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

getR :: SeqQ a -> Maybe (ViewR a)
getR s =
  case (viewr (q s)) of
    EmptyR -> Nothing
    a      -> Just a

