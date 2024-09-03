{-# LANGUAGE BangPatterns, TemplateHaskell #-}

import Control.Monad
import Control.Applicative
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Lazy as BSL
import Data.Binary (encode, decode)
import Remote

pingServer :: ProcessM ()
pingServer = forever $ do
  them <- expect
  send them ()

pingClient :: Int -> ProcessId -> ProcessM ()
pingClient n them = do
  us <- getSelfPid
  replicateM_ n $ send them us >> (expect :: ProcessM ())
  liftIO . putStrLn $ "Did " ++ show n ++ " pings"

initialProcess :: String -> ProcessM ()
initialProcess "SERVER" = do
  us <- getSelfPid
  liftIO $ BSL.writeFile "pingServer.pid" (encode us)
  pingServer
initialProcess "CLIENT" = do
  n <- liftIO $ getLine
  them <- liftIO $ decode <$> BSL.readFile "pingServer.pid"
  pingClient (read n) them

main :: IO ()
main = remoteInit (Just "config") [] initialProcess
