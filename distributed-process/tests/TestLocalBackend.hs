import System.Environment (getArgs, getProgName)
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.Local 
import Control.Concurrent (threadDelay)
import Control.Monad (replicateM)

server :: LocalBackend -> IO ()
server backend = do
  node <- newLocalNode backend
  nodes <- findPeers backend 1000000
  print nodes

client :: LocalBackend -> IO ()
client backend = do
  [node1, node2] <- replicateM 2 $ newLocalNode backend
  threadDelay 30000000 

main :: IO ()
main = do
  prog <- getProgName
  args <- getArgs

  case args of
    ["server", host, port] -> do
      backend <- initializeBackend host port initRemoteTable 
      server backend 
    ["client", host, port] -> do
      backend <- initializeBackend host port initRemoteTable 
      client backend 
    _ -> 
      putStrLn $ "usage: " ++ prog ++ " (server | client) host port"
