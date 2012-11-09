module Main where

import           Control.Distributed.Naive.Kitty
import           Control.Distributed.Platform.GenServer
import           Control.Distributed.Examples.Counter

--import           Prelude hiding (catch)
import           Control.Exception                (SomeException)
import           Control.Monad                    (void)
import           System.IO.Error                  (IOError)

import           Control.Distributed.Static       (initRemoteTable)
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)
import           System.IO
import           Control.Distributed.Process      (Process, ProcessId,
                                                   getSelfPid, liftIO, say,
                                                   spawnLocal, newChan)
import           Control.Distributed.Process.Node (LocalNode, newLocalNode,
                                                   runProcess)

host :: String
host = "::ffff:127.0.0.1"

port :: String
port = "8000"

main :: IO ()
main = do
    hSetBuffering stdout NoBuffering
    putStrLn "Starting server ... "
    t <- createTransport host port defaultTCPParameters
    case t of
        Left ex -> error $ show ex
        Right transport -> do
            putStrLn "Transport created."
            localNode <- newLocalNode transport initRemoteTable
            putStrLn "Local node created."
            --runProcess localNode startApp `catch` \e -> print (e :: IOError)
            runProcess localNode counterTest `catch` \e -> print (e :: IOError)

    putStrLn "Server done! Press key to exit ..."
    void getChar

counterTest :: Process ()
counterTest = do
    cid <- startCounter "TestCounter" 10
    c <- getCount cid

    resetCount cid
    c2 <- getCount cid
    return ()

startApp :: Process ()
startApp = do
    say "-- Starting app ..."
    kPid <- startKitty [Cat "c1" "black" "a black cat"]
    orders kPid 1000
    closeShop kPid
    return ()

orders kPid 0 = return ()
orders kPid n = do
    cat1 <- orderCat kPid "c1" "black" "a black cat"
    cat2 <- orderCat kPid "c2" "black" "a black cat"
    returnCat kPid cat1
    returnCat kPid cat2
    orders kPid (n - 1)
