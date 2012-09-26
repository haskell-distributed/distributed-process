import System.Environment (getArgs)
import System.IO
import Control.Applicative
import Control.Monad
import System.Random
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import Data.Map (Map)
import Data.Array (Array, listArray)
import qualified Data.Map as Map (fromList, toList, size, elems)

import qualified CountWords 
import qualified MapReduce
import qualified KMeans

rtable :: RemoteTable
rtable = MapReduce.__remoteTable 
       . CountWords.__remoteTable
       $ initRemoteTable 

main :: IO ()
main = do
  args <- getArgs

  case args of
    -- Local word count 
    "local" : "count" : files -> do
      input <- constructInput files 
      print $ CountWords.localCountWords input 

    -- Distributed word count
    "master" : "count" : host : port : files -> do
      input   <- constructInput files 
      backend <- initializeBackend host port rtable 
      startMaster backend $ \slaves -> do
        result <- CountWords.distrCountWords slaves input 
        liftIO $ print result 

    -- Local k-means
    "local" : "kmeans" : [] -> do
      points <- replicateM 1000 randomPoint
      let kmeans = KMeans.localKMeans (arrayFromList points) 

      let it 0 = kmeans (take 5 points)
          it n = let clusters = it (n - 1) in
                 kmeans (map snd $ Map.elems clusters) 

      forM_ ([0 .. 4] :: [Int]) $ \n -> 
        withFile ("plot" ++ show n) WriteMode $
          createGnuPlot (it n)

    -- Generic slave for distributed examples
    "slave" : host : port : [] -> do
      backend <- initializeBackend host port rtable 
      startSlave backend

--------------------------------------------------------------------------------
-- Auxiliary                                                                  --
--------------------------------------------------------------------------------

constructInput :: [FilePath] -> IO (Map FilePath CountWords.Document)
constructInput files = do
  contents <- mapM readFile files
  return . Map.fromList $ zip files contents

randomPoint :: IO KMeans.Point
randomPoint = (,) <$> randomIO <*> randomIO

arrayFromList :: [e] -> Array Int e
arrayFromList xs = listArray (0, length xs - 1) xs

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
    flatten = concat . map (\(color, (_, (points, _))) -> map (\(x, y) -> (x, y, color)) points) 

    colors :: [Float]
    colors = [0, 1 / fromIntegral (Map.size clusters) .. 1] 
