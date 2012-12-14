-- | Spine and element strict list
module Control.Distributed.Process.Internal.StrictList
  ( StrictList(..)
  , append
  , foldr
  ) where

import Prelude hiding (length, reverse, foldr)

-- | Strict list
data StrictList a
   = Cons !a !(StrictList a)
   | Nil
   | Snoc !(StrictList a) !a
   | Append !(StrictList a) !(StrictList a)

append :: StrictList a -> StrictList a -> StrictList a
append Nil l = l
append l Nil = l
append l1 l2 = l1 `Append` l2

foldr :: (a -> b -> b) -> b -> StrictList a -> b
foldr f c0 xs0 = go xs0 c0
  where go Nil            c = c
        go (Cons x xs)    c = f x (go xs c)
        go (Snoc xs x)    c = go xs (f x c)
        go (Append xs ys) c = go xs (go ys c)
