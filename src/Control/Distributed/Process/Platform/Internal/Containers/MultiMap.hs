{-# LANGUAGE ExistentialQuantification  #-}
module Control.Distributed.Process.Platform.Internal.Containers.MultiMap
  ( MultiMap
  , empty
  , insert
  , member
  , lookup
  , filter
  , filterWithKey
  ) where

import qualified Data.Foldable as Foldable

import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import Data.HashSet (HashSet)
import qualified Data.HashSet as Set

import Prelude hiding (lookup, filter, pred)

-- | Class of things that can be inserted in a map or
-- a set (of mapped values), for which instances of
-- @Eq@ and @Hashable@ must be present.
--
class (Eq a, Hashable a) => Insertable a

-- | Opaque type of MultiMaps.
type MultiMap k v = HashMap k (HashSet v)

empty :: MultiMap k v
empty = Map.empty

insert :: forall k v. (Insertable k, Insertable v)
       => k -> v -> MultiMap k v -> MultiMap k v
insert k' v' m =
  case Map.lookup k' m of
    Nothing -> Map.insert k' (Set.singleton v') m
    Just s  -> Map.insert k' (Set.insert v' s) m

member :: (Insertable k) => k -> MultiMap k a -> Bool
member = Map.member

lookup :: (Insertable k) => k -> MultiMap k v -> Maybe [v]
lookup k m = maybe Nothing (Just . Foldable.toList) $ Map.lookup k m

filter :: forall k v. (Insertable k)
       => (v -> Bool)
       -> MultiMap k v
       -> MultiMap k v
filter p m = Map.foldlWithKey' (matchOn p) m m
  where
    matchOn pred acc key valueSet =
      Map.insert key (Set.filter pred valueSet) acc

filterWithKey :: forall k v. (Insertable k)
              => (k -> v -> Bool)
              -> MultiMap k v
              -> MultiMap k v
filterWithKey p m = Map.foldlWithKey' (matchOn p) m m
  where
    matchOn pred acc key valueSet =
      Map.insert key (Set.filter (pred key) valueSet) acc

