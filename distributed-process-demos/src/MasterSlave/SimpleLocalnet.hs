import System.Environment (getArgs)
import Control.Exception (evaluate)
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import qualified MasterSlave

rtable :: RemoteTable
rtable = MasterSlave.__remoteTable initRemoteTable 

main :: IO ()
main = do
  args <- getArgs

  case args of
    ["master", host, port, strN, strSpawnStrategy] -> do
      backend <- initializeBackend host port rtable 
      n             <- evaluate $ read strN
      spawnStrategy <- evaluate $ read strSpawnStrategy
      startMaster backend $ \slaves -> do
        result <- MasterSlave.master n spawnStrategy slaves
        liftIO $ print result 
    ["slave", host, port] -> do
      backend <- initializeBackend host port rtable 
      startSlave backend
