{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable, GADTs #-}
module MapReduce 
  ( -- * Map-reduce skeleton and implementation
    MapReduce(..)
  , localMapReduce
    -- * Map-reduce algorithmic components
  , reducePerKey
  , groupByKey
    -- * Re-exports from Data.Map
  , Map
  ) where

import Data.Typeable (Typeable)
import Data.Map (Map)
import qualified Data.Map as Map (mapWithKey, fromListWith, toList)
import Control.Arrow (second)

--------------------------------------------------------------------------------
-- Definition of a MapReduce skeleton and a local implementation              --
--------------------------------------------------------------------------------

-- | MapReduce skeleton
data MapReduce k1 v1 k2 v2 v3 = MapReduce {
    mrMap    :: k1 -> v1 -> [(k2, v2)]
  , mrReduce :: k2 -> [v2] -> v3
  } deriving (Typeable)

-- | Local (non-distributed) implementation of the map-reduce algorithm
--
-- This can be regarded as the specification of map-reduce; see
-- /Google’s MapReduce Programming Model---Revisited/ by Ralf Laemmel
-- (<http://userpages.uni-koblenz.de/~laemmel/MapReduce/>).
localMapReduce :: forall k1 k2 v1 v2 v3. Ord k2 =>
                  MapReduce k1 v1 k2 v2 v3 
               -> Map k1 v1 
               -> Map k2 v3
localMapReduce mr = reducePerKey mr . groupByKey . mapPerKey mr

reducePerKey :: MapReduce k1 v1 k2 v2 v3 -> Map k2 [v2] -> Map k2 v3
reducePerKey mr = Map.mapWithKey (mrReduce mr) 

groupByKey :: Ord k2 => [(k2, v2)] -> Map k2 [v2]
groupByKey = Map.fromListWith (++) . map (second return) 

mapPerKey :: MapReduce k1 v1 k2 v2 v3 -> Map k1 v1 -> [(k2, v2)]
mapPerKey mr = concatMap (uncurry (mrMap mr)) . Map.toList 
