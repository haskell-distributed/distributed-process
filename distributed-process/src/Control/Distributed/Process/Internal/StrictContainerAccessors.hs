module Control.Distributed.Process.Internal.StrictContainerAccessors
  ( mapMaybe
  , mapDefault
  ) where

import Prelude hiding (map)
import Data.Accessor
import Data.Map (Map)
import qualified Data.Map as Map (lookup, insert, delete, findWithDefault)

mapMaybe :: Ord key => key -> Accessor (Map key elem) (Maybe elem)
mapMaybe key = accessor
  (Map.lookup key)
  (\mVal map -> case mVal of
      Nothing  -> Map.delete key map
      Just val -> val `seq` Map.insert key val map)

mapDefault :: Ord key => elem -> key -> Accessor (Map key elem) elem
mapDefault def key = accessor
  (Map.findWithDefault def key)
  (\val map -> val `seq` Map.insert key val map)
