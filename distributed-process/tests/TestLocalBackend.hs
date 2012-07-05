import System.Environment (getArgs, getProgName)
import Control.Distributed.Process (say)
import Control.Distributed.Process.Node 
  ( initRemoteTable
  , forkProcess
  , runProcess
  )
import Control.Distributed.Process.Backend.Local 
import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)

server :: LocalBackend -> IO ()
server backend = do
  node <- newLocalNode backend
  runProcess node $ 
    say "this is the server"
  {-
  nodes <- findPeers backend 1000000
  print nodes
  -}
  threadDelay 30000000 

client :: LocalBackend -> IO ()
client backend = do
  node <- newLocalNode backend
  forkProcess node . forever $ do
    say "this is a client node1" 
    liftIO $ threadDelay 5000000
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
