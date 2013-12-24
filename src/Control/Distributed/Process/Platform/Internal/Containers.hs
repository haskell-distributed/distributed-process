module Control.Distributed.Process.Internal.Containers where

class (Eq k, Functor m) => Map m k | m -> k where
  empty         :: m a
  member        :: k -> m a -> Bool
  insert        :: k -> a -> m a -> m a
  delete        :: k -> m a -> m a
  lookup        :: k -> m a -> a
  filter        :: (a -> Bool) -> m a -> m a
  filterWithKey :: (k -> a -> Bool) -> m a -> m a

