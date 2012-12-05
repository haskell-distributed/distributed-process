module Main where

import           Control.Distributed.Examples.Counter
import           Control.Distributed.Examples.Kitty

import           Control.Exception                    (AsyncException (..),
                                                       SomeException, catchJust)
import           Control.Monad                        (void)
import           System.IO.Error                      (IOError)

import           Control.Distributed.Static           (initRemoteTable)
import           Network.Transport                    (closeTransport)
import           Network.Transport.TCP                (createTransport,
                                                       defaultTCPParameters)

import           Control.Distributed.Process          (Process, ProcessId,
                                                       getSelfPid, liftIO,
                                                       newChan, say, spawnLocal)
import           Control.Distributed.Process.Node     (LocalNode, newLocalNode,
                                                       runProcess)
import           System.IO

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
            runProcess localNode (kittyTest 1000) `catch` \e -> print (e :: IOError)
            --runProcess localNode counterTest `catch` \e -> print (e :: IOError)
            putStrLn "Server started!"
            getChar
            return ()



counterTest :: Process ()
counterTest = do
    say "-- Starting counter test ..."
    cid <- startCounter 10
    c <- getCount cid
    say $ "c = " ++ show c
    incCount cid
    incCount cid
    c <- getCount cid
    say $ "c = " ++ show c
    resetCount cid
    c2 <- getCount cid
    say $ "c2 = " ++ show c2

    stopCounter cid
    return ()



kittyTest :: Int -> Process ()
kittyTest n = do
    say "-- Starting kitty test ..."
    kPid <- startKitty [Cat "c1" "black" "a black cat"]
    say $ "-- Ordering " ++ show n ++  " cats ..."
    kittyTransactions kPid n
    say "-- Closing kitty shop ..."
    closeShop kPid
    return ()



kittyTransactions kPid 0 = return ()
kittyTransactions kPid n = do
    cat1 <- orderCat kPid "c1" "black" "a black cat"
    cat2 <- orderCat kPid "c2" "black" "a black cat"
    returnCat kPid cat1
    returnCat kPid cat2
    kittyTransactions kPid (n - 1)
