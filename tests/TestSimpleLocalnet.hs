import System.Environment (getArgs, getProgName)
import Control.Distributed.Process (NodeId, Process, liftIO)
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet

master :: Backend -> [NodeId] -> Process ()
master backend slaves = do
  liftIO . putStrLn $ "Slaves: " ++ show slaves
  terminateAllSlaves backend

main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs

  case args of
    ["master", host, port] -> do
      backend <- initializeBackend host port initRemoteTable
      startMaster backend (master backend)
    ["slave", host, port] -> do
      backend <- initializeBackend host port initRemoteTable
      startSlave backend
    _ ->
      putStrLn $ "usage: " ++ prog ++ " (master | slave) host port"
