import System.Environment (getArgs)
import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Backend.Azure 
import qualified MasterSlave

azureMaster :: ([NodeId], Integer) -> Backend -> Process ()
azureMaster (slaves, n) _backend = do
  result <- MasterSlave.master n slaves
  mapM_ terminateNode slaves 
  remoteSend result

remotable ['azureMaster]

printResult :: LocalProcess ()
printResult = do
  result <- localExpect :: LocalProcess Integer
  liftIO $ print result 

main :: IO ()
main = do
  args <- getArgs
  case args of
    "onvm":args' -> onVmMain (__remoteTable . MasterSlave.__remoteTable) args'
    [sid, x509, pkey, user, cloudService, n] -> do
      params <- defaultAzureParameters sid x509 pkey 
      let params' = params { azureSshUserName = user }
      backend <- initializeBackend params' cloudService
      vms <- findVMs backend
      print vms
      nids <- forM vms $ \vm -> spawnNodeOnVM backend vm "8080"
      callOnVM backend (head vms) "8081" $ 
        ProcessPair ($(mkClosure 'azureMaster) (nids, read n :: Integer)) 
                    printResult 
    _ ->
      error "Invalid command line arguments"
