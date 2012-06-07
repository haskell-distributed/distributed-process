module Main where 

import Data.Binary (Binary)
import Data.Typeable (Typeable)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar ( newEmptyMVar
                               , putMVar
                               , takeMVar
                               , readMVar
                               )
import Control.Monad (replicateM_)
import Control.Distributed.Process
import Network.Transport.TCP (createTransport, defaultTCPParameters)

newtype Ping = Ping ProcessId
  deriving (Typeable, Binary, Show)

newtype Pong = Pong ProcessId
  deriving (Typeable, Binary, Show)

ping :: Process ()
ping = do
  Pong partner <- expect
  self <- getSelfPid
  send partner (Ping self)
  ping

testPing :: IO ()
testPing = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters 
    localNode <- newLocalNode transport
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    Right transport <- createTransport "127.0.0.1" "8081" defaultTCPParameters 
    localNode <- newLocalNode transport
    pingServer <- readMVar serverAddr

    let numPings = 10000

    runProcess localNode $ do
      pid <- getSelfPid
      replicateM_ numPings $ do
        send pingServer (Pong pid)
        Ping _ <- expect
        return ()

    putStrLn $ "Client did " ++ show numPings ++ " pings"
    putMVar clientDone ()


  takeMVar clientDone

main :: IO ()
main = testPing 
