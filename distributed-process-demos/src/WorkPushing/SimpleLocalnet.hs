import System.Environment (getArgs)
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import qualified WorkPushing

rtable :: RemoteTable
rtable = WorkPushing.__remoteTable initRemoteTable 

main :: IO ()
main = do
  args <- getArgs

  case args of
    ["master", host, port, n] -> do
      backend <- initializeBackend host port rtable 
      startMaster backend $ \slaves -> do
        result <- WorkPushing.master (read n) slaves
        liftIO $ print result 
    ["slave", host, port] -> do
      backend <- initializeBackend host port rtable 
      startSlave backend
