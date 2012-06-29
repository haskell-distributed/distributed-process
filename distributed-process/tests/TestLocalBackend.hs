import System.Environment (getArgs, getProgName)
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.Local 
import Control.Concurrent (threadDelay)

server :: LocalBackend -> IO ()
server backend = do
  nodes <- findPeers backend
  print nodes

client :: LocalBackend -> IO ()
client _ = threadDelay 30000000 

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
