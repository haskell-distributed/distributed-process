{-# LANGUAGE BangPatterns #-}

-- | Like Throughput, but send every ping from a different process
-- (i.e., require a lightweight connection per ping)
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
        Just them -> send them n >> go 0

count :: Int -> ProcessId -> Process ()
count n them = do
  us <- getSelfPid
  replicateM_ n . spawnLocal $ send them (Nothing :: Maybe ProcessId)
  send them (Just us)
  n' <- expect
  liftIO $ print (n == n')

initialProcess :: String -> Process ()
initialProcess "SERVER" = do
  us <- getSelfPid
  liftIO $ BSL.writeFile "counter.pid" (encode us)
  counter
initialProcess "CLIENT" = do
  n <- liftIO $ getLine
  them <- liftIO $ decode <$> BSL.readFile "counter.pid"
  count (read n) them

main :: IO ()
main = do
  [role, host, port] <- getArgs
  Right transport <- createTransport host port defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  runProcess node $ initialProcess role
