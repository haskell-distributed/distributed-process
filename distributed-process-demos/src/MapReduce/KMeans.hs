module KMeans 
  ( Point
  , Cluster
  , localKMeans
  ) where

import Data.List (minimumBy)
import Data.Function (on)
import Data.Array (Array, (!), bounds)
import qualified Data.Map as Map (fromList)
import MapReduce

type Point    = (Double, Double)
type Cluster  = (Double, Double)

average :: Fractional a => [a] -> a
average xs = sum xs / fromIntegral (length xs)

distanceSq :: Point -> Point -> Double 
distanceSq (x1, y1) (x2, y2) = a * a + b * b
  where
    a = x2 - x1
    b = y2 - y1

nearest :: Point -> [Cluster] -> Cluster
nearest p = minimumBy (compare `on` distanceSq p) 

center :: [Point] -> Point
center ps = let (xs, ys) = unzip ps in (average xs, average ys) 

kmeans :: Array Int Point -> MapReduce (Int, Int) [Cluster] Cluster Point ([Point], Point)
kmeans points = MapReduce {
    mrMap    = \(lo, hi) cs -> [ let p = points ! i in (nearest p cs, p)
                               | i <- [lo .. hi]
                               ] 
  , mrReduce = \_ ps -> (ps, center ps)
  }

localKMeans :: Array Int Point -> [Cluster] -> Map Cluster ([Point], Point)
localKMeans points cs = 
  localMapReduce (kmeans points) (Map.fromList [(bounds points, cs)]) 
