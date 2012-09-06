import System.Environment
import Control.Monad
import Control.Applicative
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Data.Binary (encode, decode)
import qualified Data.ByteString.Lazy as BSL

counter :: Process ()
counter = go 0
  where
    go :: Int -> Process () 
    go !n = do
      b <- expect
      case b of
        Nothing   -> go (n + 1)
        Just them -> send them n 

count :: Int -> ProcessId -> Process ()
count n them = do
  us <- getSelfPid
  replicateM_ n $ send them (Nothing :: Maybe ProcessId)
  send them (Just us)
  n' <- expect
  liftIO $ print (n == n')

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["server", host, port] -> do
      Right transport <- createTransport host port defaultTCPParameters
      node <- newLocalNode transport initRemoteTable 
      runProcess node $ do
        us <- getSelfPid
        liftIO $ BSL.writeFile "counter.pid" (encode us)
        counter
    ["client", host, port, n] ->  do
      Right transport <- createTransport host port defaultTCPParameters
      node <- newLocalNode transport initRemoteTable 
      runProcess node $ do
        them <- liftIO $ decode <$> BSL.readFile "counter.pid"
        count (read n) them
    _ -> error "Invalid arguments"
      
