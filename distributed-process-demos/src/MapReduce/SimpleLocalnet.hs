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
import qualified Data.Map as Map (fromList)

import qualified CountWords 
import qualified MapReduce
import qualified KMeans

rtable :: RemoteTable
rtable = MapReduce.__remoteTable 
       . CountWords.__remoteTable
       . KMeans.__remoteTable
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
      withFile "plot.data" WriteMode $ KMeans.createGnuPlot $
        KMeans.localKMeans (arrayFromList points) (take 5 points) 5 

    -- Distributed k-means
    "master" : "kmeans" : host : port : [] -> do
      points  <- replicateM 1000 randomPoint
      backend <- initializeBackend host port rtable 
      startMaster backend $ \slaves -> do
        result <- KMeans.distrKMeans (arrayFromList points) (take 5 points) slaves 5
        liftIO $ withFile "plot.data" WriteMode $ KMeans.createGnuPlot result

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
