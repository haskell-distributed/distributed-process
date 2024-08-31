{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE TupleSections              #-}

module Control.Distributed.Process.Extras.Internal.Containers.MultiMap
  ( MultiMap
  , Insertable
  , empty
  , insert
  , member
  , lookup
  , delete
  , filter
  , filterWithKey
  , foldrWithKey
  , toList
  , size
  ) where

import qualified Data.Foldable as Foldable
import Data.Foldable (Foldable)

import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import Data.HashSet (HashSet)
import qualified Data.HashSet as Set
import Data.Foldable (Foldable(foldr))
import Prelude hiding (lookup, filter, pred)

-- | Class of things that can be inserted in a map or
-- a set (of mapped values), for which instances of
-- @Eq@ and @Hashable@ must be present.
--
class (Eq a, Hashable a) => Insertable a
instance (Eq a, Hashable a) => Insertable a

-- | Opaque type of MultiMaps.
data MultiMap k v = M { hmap :: !(HashMap k (HashSet v)) }

-- instance Foldable

instance Foldable (MultiMap k) where
  foldr f = foldrWithKey (const f)

empty :: MultiMap k v
empty = M $ Map.empty

size :: MultiMap k v -> Int
size = Map.size . hmap

insert :: forall k v. (Insertable k, Insertable v)
       => k -> v -> MultiMap k v -> MultiMap k v
insert k' v' M{..} =
  case Map.lookup k' hmap of
    Nothing -> M $ Map.insert k' (Set.singleton v') hmap
    Just s  -> M $ Map.insert k' (Set.insert v' s) hmap
{-# INLINE insert #-}

member :: (Insertable k) => k -> MultiMap k a -> Bool
member k = Map.member k . hmap

lookup :: (Insertable k) => k -> MultiMap k v -> Maybe [v]
lookup k M{..} = maybe Nothing (Just . Foldable.toList) $ Map.lookup k hmap
{-# INLINE lookup #-}

delete :: (Insertable k) => k -> MultiMap k v -> Maybe ([v], MultiMap k v)
delete k m@M{..} = maybe Nothing (Just . (, M $ Map.delete k hmap)) $ lookup k m

filter :: forall k v. (Insertable k)
       => (v -> Bool)
       -> MultiMap k v
       -> MultiMap k v
filter p M{..} = M $ Map.foldlWithKey' (matchOn p) hmap hmap
  where
    matchOn pred acc key valueSet =
      let vs = Set.filter pred valueSet in
      if Set.null vs then acc else Map.insert key vs acc
{-# INLINE filter #-}

filterWithKey :: forall k v. (Insertable k)
              => (k -> v -> Bool)
              -> MultiMap k v
              -> MultiMap k v
filterWithKey p M{..} = M $ Map.foldlWithKey' (matchOn p) hmap hmap
  where
    matchOn pred acc key valueSet =
      let vs = Set.filter (pred key) valueSet in
      if Set.null vs then acc else Map.insert key vs acc
{-# INLINE filterWithKey #-}

-- | /O(n)/ Reduce this map by applying a binary operator to all
-- elements, using the given starting value (typically the
-- right-identity of the operator).
foldrWithKey :: (k -> v -> a -> a) -> a -> MultiMap k v -> a
foldrWithKey f a M{..} =
  let wrap = \k' v' acc' -> f k' v' acc'
  in Map.foldrWithKey (\k v acc -> Set.foldr (wrap k) acc v) a hmap
{-# INLINE foldrWithKey #-}

toList :: MultiMap k v -> [(k, v)]
toList M{..} = Map.foldlWithKey' explode [] hmap
  where
    explode xs k vs = Set.foldl' (\ys v -> ((k, v):ys)) xs vs
{-# INLINE toList #-}
