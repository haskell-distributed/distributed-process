{-# LANGUAGE TemplateHaskell #-}

import Data.Binary (encode, decode)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (try, IOException)
import Control.Distributed.Process 
  ( Process
  , getSelfPid
  , expect
  , send
  , monitor
  , receiveWait
  , match
  , ProcessMonitorNotification(..)
  )
import Control.Distributed.Process.Closure (remotable, mkClosure) 
import Control.Distributed.Process.Backend.Azure 
  ( Backend
  , ProcessPair(..)
  , RemoteProcess
  , LocalProcess
  , localExpect
  , remoteSend
  )
import Control.Distributed.Process.Backend.Azure.GenericMain (genericMain) 
import qualified Data.ByteString.Lazy as BSL (readFile, writeFile) 

pingClient :: () -> Backend -> Process () 
pingClient () _backend = do
  mPingServerEnc <- liftIO $ try (BSL.readFile "pingServer.pid")
  case mPingServerEnc of
    Left err -> 
      remoteSend $ "Ping server not found: " ++ show (err :: IOException)
    Right pingServerEnc -> do 
      let pingServerPid = decode pingServerEnc
      pid <- getSelfPid
      _ref <- monitor pingServerPid 
      send pingServerPid pid
      gotReply <- receiveWait 
        [ match (\() -> return True)
        , match (\(ProcessMonitorNotification {}) -> return False)
        ]
      if gotReply
        then remoteSend $ "Ping server at " ++ show pingServerPid ++ " ok"
        else remoteSend $ "Ping server at " ++ show pingServerPid ++ " failure"

pingServer :: () -> Backend -> Process ()
pingServer () _backend = do
  us <- getSelfPid
  liftIO $ BSL.writeFile "pingServer.pid" (encode us)
  forever $ do 
    them <- expect
    send them ()

remotable ['pingClient, 'pingServer]

receiveString :: LocalProcess ()
receiveString = localExpect >>= liftIO . putStrLn 

main :: IO ()
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable "ping"       = return $ ProcessPair ($(mkClosure 'pingClient) ()) receiveString 
    callable _            = error "callable: unknown"

    spawnable :: String -> IO (RemoteProcess ())
    spawnable "pingServer" = return $ ($(mkClosure 'pingServer) ()) 
    spawnable _            = error "spawnable: unknown"
