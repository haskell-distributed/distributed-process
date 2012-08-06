{-# LANGUAGE TemplateHaskell #-}

import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay)
import Control.Distributed.Process (Process, ProcessId, getSelfPid, Closure)
import Control.Distributed.Process.Closure (remotable, mkClosure, sdictProcessId)
import Control.Distributed.Process.Backend.Azure.GenericMain 
  ( genericMain
  , ProcessPair(..)
  )

getPid :: () -> Process ProcessId
getPid () = do
  liftIO $ appendFile "Log" "getPid did run" 
  getSelfPid

logN :: Int -> Process () 
logN 0 = 
  liftIO $ appendFile "Log" "logN done\n" 
logN n = do
  liftIO $ do
    appendFile "Log" $ "logN " ++ show n ++ "\n"
    threadDelay 1000000
  logN (n - 1)

remotable ['getPid, 'logN]

main :: IO ()
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable "getPid" = return $ ProcessPair ($(mkClosure 'getPid) ()) print sdictProcessId
    callable _       = error "spawnable: unknown"

    spawnable :: String -> IO (Closure (Process ()))
    spawnable "logN" = return $ $(mkClosure 'logN) (10 :: Int)
    spawnable _      = error "callable: unknown"
