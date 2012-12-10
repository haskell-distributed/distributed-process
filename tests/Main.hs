module Main where

import Prelude hiding (catch)
import           GenServer.Counter
import           GenServer.Kitty
import           Control.Exception                    (SomeException)
import           Control.Distributed.Static           (initRemoteTable)
import           Network.Transport.TCP                (createTransport,
                                                       defaultTCPParameters)
import           Control.Distributed.Process          (Process, catch, say)
import           Control.Distributed.Process.Node     (newLocalNode, runProcess)
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
            runProcess localNode $ (kittyTest 10) `catch` \e -> say $ show (e :: SomeException)
            runProcess localNode $ counterTest `catch` \e -> say $ show (e :: SomeException)
            --putStrLn "Server started!"
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
    terminateCounter cid
    return ()



kittyTest :: Int -> Process ()
kittyTest n = do
    say "-- Starting kitty test ..."
    kPid <- startKitty [Cat "c1" "black" "a black cat"]
    say $ "-- Ordering " ++ show n ++  " cats ..."
    kittyTransactions kPid n
    say "-- Closing kitty shop ..."
    closeShop kPid
    say "-- Stopping kitty shop ..."
    terminateKitty kPid
    closeShop kPid
    return ()



kittyTransactions kPid 0 = return ()
kittyTransactions kPid n = do
    say "ca1"
    cat1 <- orderCat kPid "c1" "black" "a black cat"
    say "a2"
    a2 <- orderCatAsync kPid "c2" "black" "a black cat"
    say "cat2"
    cat2 <- waitTimeout a2 Infinity
    returnCat kPid cat1
    returnCat kPid cat2
    kittyTransactions kPid (n - 1)
