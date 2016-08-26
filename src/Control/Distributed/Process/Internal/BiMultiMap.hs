-- | This is an implementation of bidirectional multimaps.
module Control.Distributed.Process.Internal.BiMultiMap
  ( BiMultiMap
  , empty
  , singleton
  , size
  , insert
  , lookupBy1st
  , lookupBy2nd
  , delete
  , deleteAllBy1st
  , deleteAllBy2nd
  , partitionWithKeyBy1st
  , partitionWithKeyBy2nd
  , flip
  ) where

import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Prelude hiding (flip, lookup)

-- | A bidirectional multimaps @BiMultiMap a b v@ is a set of triplets of type
-- @(a, b, v)@.
--
-- It is possible to lookup values by using either @a@ or @b@ as keys.
--
data BiMultiMap a b v = BiMultiMap !(Map a (Set (b, v))) !(Map b (Set (a, v)))

-- The bidirectional multimap is implemented with a pair of multimaps.
--
-- Each multimap represents a set of triples, and one invariant is that both
-- multimaps should represent exactly the same set of triples.
--
-- Each of the multimaps, however, uses a different component of the triplets
-- as key. This allows to do efficient deletions by any of the two components.

-- | The empty bidirectional multimap.
empty :: BiMultiMap a b v
empty = BiMultiMap Map.empty Map.empty

-- | A bidirectional multimap containing a single triplet.
singleton :: (Ord a, Ord b, Ord v) => a -> b -> v -> BiMultiMap a b v
singleton a b v = insert a b v empty

-- | Yields the amount of triplets in the multimap.
size :: BiMultiMap a b v -> Int
size (BiMultiMap m _) = foldl' (+) 0 $ map Set.size $ Map.elems m

-- | Inserts a triplet in the multimap.
insert :: (Ord a, Ord b, Ord v)
       => a -> b -> v -> BiMultiMap a b v -> BiMultiMap a b v
insert a b v (BiMultiMap m r) =
    BiMultiMap (Map.insertWith (\_new old -> Set.insert (b, v) old)
                               a
                               (Set.singleton (b, v))
                               m)
               (Map.insertWith (\_new old -> Set.insert (a, v) old)
                               b
                               (Set.singleton (a, v))
                               r)

-- | Looks up all the triplets whose first component is the given value.
lookupBy1st :: Ord a => a -> BiMultiMap a b v -> Set (b, v)
lookupBy1st a (BiMultiMap m _) = maybe Set.empty id $ Map.lookup a m

-- | Looks up all the triplets whose second component is the given value.
lookupBy2nd :: Ord b => b -> BiMultiMap a b v -> Set (a, v)
lookupBy2nd b = lookupBy1st b . flip

-- | Deletes a triplet. It yields the original multimap if the triplet is
-- not present.
delete :: (Ord a, Ord b, Ord v)
       => a -> b -> v -> BiMultiMap a b v -> BiMultiMap a b v
delete a b v (BiMultiMap m r) =
  let m' = Map.update (nothingWhen Set.null . Set.delete (b, v)) a m
      r' = Map.update (nothingWhen Set.null . Set.delete (a, v)) b r
   in BiMultiMap m' r'

-- | Deletes all triplets whose first component is the given value.
deleteAllBy1st :: (Ord a, Ord b, Ord v) => a -> BiMultiMap a b v -> BiMultiMap a b v
deleteAllBy1st a (BiMultiMap m r) =
  let (mm, m') = Map.updateLookupWithKey (\_ _ -> Nothing) a m
      r' = case mm of
            Nothing -> r
            Just mb -> reverseDelete a (Set.toList mb) r
   in BiMultiMap m' r'

-- | Like 'deleteAllBy1st' but deletes by the second component of the triplets.
deleteAllBy2nd :: (Ord a, Ord b, Ord v)
               => b -> BiMultiMap a b v -> BiMultiMap a b v
deleteAllBy2nd b = flip . deleteAllBy1st b . flip

-- | Yields the triplets satisfying the given predicate, and a multimap
-- with all this triplets removed.
partitionWithKeyBy1st :: (Ord a, Ord b, Ord v)
                      => (a -> Set (b, v) -> Bool) -> BiMultiMap a b v
                      -> (Map a (Set (b, v)), BiMultiMap a b v)
partitionWithKeyBy1st p (BiMultiMap m r) =
    let (m0, m1) = Map.partitionWithKey p m
        r1 = foldl' (\rr (a, mb) -> reverseDelete a (Set.toList mb) rr) r $
               Map.toList m0
     in (m0, BiMultiMap m1 r1)

-- | Like 'partitionWithKeyBy1st' but the predicates takes the second component
-- of the triplets as first argument.
partitionWithKeyBy2nd :: (Ord a, Ord b, Ord v)
                      => (b -> Set (a, v) -> Bool) -> BiMultiMap a b v
                      -> (Map b (Set (a, v)), BiMultiMap a b v)
partitionWithKeyBy2nd p b = let (m, b') = partitionWithKeyBy1st p $ flip b
                             in (m, flip b')

-- | Exchange the first and the second components of all triplets.
flip :: BiMultiMap a b v -> BiMultiMap b a v
flip (BiMultiMap m r) = BiMultiMap r m

-- Internal functions

-- | @reverseDelete a bs m@ removes from @m@ all the triplets wich have @a@ as
-- first component and second and third components in @bs@.
--
-- The @m@ map is in reversed form, meaning that the second component of the
-- triplets is used as key.
reverseDelete :: (Ord a, Ord b, Ord v)
              => a -> [(b, v)] -> Map b (Set (a, v)) -> Map b (Set (a, v))
reverseDelete a bs r = foldl' (\rr (b, v) -> Map.update (rmb v) b rr) r bs
  where
    rmb v = nothingWhen Set.null . Set.delete (a, v)

-- | @nothingWhen p a@ is @Just a@ when @a@ satisfies predicate @p@.
-- Yields @Nothing@ otherwise.
nothingWhen :: (a -> Bool) -> a -> Maybe a
nothingWhen p a = if p a then Nothing else Just a
