import System.Environment (getArgs)
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import Data.Map (Map)
import qualified Data.Map as Map (fromList)

import qualified CountWords 
import qualified MapReduce

rtable :: RemoteTable
rtable = MapReduce.__remoteTable 
       . CountWords.__remoteTable
       $ initRemoteTable 

constructInput :: [FilePath] -> IO (Map FilePath CountWords.Document)
constructInput files = do
  contents <- mapM readFile files
  return . Map.fromList $ zip files contents

main :: IO ()
main = do
  args <- getArgs

  case args of
    "local" : "count" : files -> do
      input <- constructInput files 
      print . CountWords.localCountWords $ input 
    "master" : "count" : host : port : files -> do
      input   <- constructInput files 
      backend <- initializeBackend host port rtable 
      startMaster backend $ \slaves -> do
        result <- CountWords.distrCountWords slaves input 
        liftIO $ print result 
    "slave" : host : port : [] -> do
      backend <- initializeBackend host port rtable 
      startSlave backend
