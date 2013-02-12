-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Internal.Queue.SeqQ
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
--
-- A simple queue implementation backed by @Data.Sequence@.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Internal.Queue.SeqQ
  ( SeqQ
  , empty
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
import qualified Data.Sequence as Seq (empty, singleton)

newtype SeqQ a = SeqQ { q :: Seq a }

{-# INLINE empty #-}
empty :: SeqQ a
empty = SeqQ Seq.empty

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
