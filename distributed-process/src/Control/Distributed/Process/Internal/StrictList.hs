-- | Spine and element strict list
module Control.Distributed.Process.Internal.StrictList 
  ( StrictList(Cons, Nil)
  , length 
  , reverse
  , reverse'
  ) where

import Prelude hiding (length, reverse)

-- | Strict list
data StrictList a = Cons !a !(StrictList a) | Nil

length :: StrictList a -> Int
length Nil         = 0
length (Cons _ xs) = 1 + length xs

-- | Reverse a strict list
reverse :: StrictList a -> StrictList a 
reverse xs = reverse' xs Nil

-- | @reverseStrict' xs ys@ is 'reverse xs ++ ys' if they were lists
reverse' :: StrictList a -> StrictList a -> StrictList a 
reverse' Nil         ys = ys
reverse' (Cons x xs) ys = reverse' xs (Cons x ys)
