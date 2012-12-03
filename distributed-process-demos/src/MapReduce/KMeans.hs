{-# LANGUAGE TupleSections #-}
module KMeans
  ( Point
  , Cluster
  , localKMeans
  , distrKMeans
  , createGnuPlot
  , __remoteTable
  ) where

import System.IO
import Data.List (minimumBy)
import Data.Function (on)
import Data.Array (Array, (!), bounds)
import qualified Data.Map as Map (fromList, elems, toList, size)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import MapReduce
import PolyDistrMapReduce hiding (__remoteTable)

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

localKMeans :: Array Int Point
            -> [Cluster]
            -> Int
            -> Map Cluster ([Point], Point)
localKMeans points cs iterations = go (iterations - 1)
  where
    mr :: [Cluster] -> Map Cluster ([Point], Point)
    mr = localMapReduce (kmeans points) . trivialSegmentation

    go :: Int -> Map Cluster ([Point], Point)
    go 0 = mr cs
    go n = mr . map snd . Map.elems . go $ n - 1

    trivialSegmentation :: [Cluster] -> Map (Int, Int) [Cluster]
    trivialSegmentation cs' = Map.fromList [(bounds points, cs')]

dictIn :: SerializableDict ((Int, Int), [Cluster])
dictIn = SerializableDict

dictOut :: SerializableDict [(Cluster, Point)]
dictOut = SerializableDict

remotable ['kmeans, 'dictIn, 'dictOut]

distrKMeans :: Array Int Point
            -> [Cluster]
            -> [NodeId]
            -> Int
            -> Process (Map Cluster ([Point], Point))
distrKMeans points cs mappers iterations =
    distrMapReduce $(mkStatic 'dictIn)
                   $(mkStatic 'dictOut)
                   ($(mkClosure 'kmeans) points)
                   mappers
                   (go (iterations - 1))
  where
    go :: Int
       -> (Map (Int, Int) [Cluster] -> Process (Map Cluster ([Point], Point)))
       -> Process (Map Cluster ([Point], Point))
    go 0 iteration =
      iteration (Map.fromList $ map (, cs) segments)
    go n iteration = do
      clusters <- go (n - 1) iteration
      let centers = map snd $ Map.elems clusters
      iteration (Map.fromList $ map (, centers) segments)

    segments :: [(Int, Int)]
    segments = let (lo, _) = bounds points in dividePoints numPoints lo

    dividePoints :: Int -> Int -> [(Int, Int)]
    dividePoints pointsLeft offset
      | pointsLeft <= pointsPerMapper = [(offset, offset + pointsLeft - 1)]
      | otherwise = let offset' = offset + pointsPerMapper in
                    (offset, offset' - 1)
                  : dividePoints (pointsLeft - pointsPerMapper) offset'

    pointsPerMapper :: Int
    pointsPerMapper =
      ceiling (toRational numPoints / toRational (length mappers))

    numPoints :: Int
    numPoints = let (lo, hi) = bounds points in hi - lo + 1

-- | Create a gnuplot data file for the output of the k-means algorithm
--
-- To plot the data, use
--
-- > plot "<<filename>>" u 1:2:3 with points palette
createGnuPlot :: Map KMeans.Cluster ([KMeans.Point], KMeans.Point) -> Handle -> IO ()
createGnuPlot clusters h =
    mapM_ printPoint . flatten . zip colors . Map.toList $ clusters
  where
    printPoint (x, y, color) =
      hPutStrLn h $ show x ++ " " ++ show y ++ " " ++ show color

    flatten :: [(Float, (KMeans.Cluster, ([KMeans.Point], KMeans.Point)))]
            -> [(Double, Double, Float)]
    flatten = concatMap (\(color, (_, (points, _))) -> map (\(x, y) -> (x, y, color)) points)

    colors :: [Float]
    colors = [0, 1 / fromIntegral (Map.size clusters) .. 1]
