{-# LANGUAGE TemplateHaskell #-}

import Data.Binary (encode, decode)
import Control.Applicative ((<$>))
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay)
import Control.Exception (try, IOException)
import Control.Distributed.Process 
  ( Process
  , ProcessId
  , getSelfPid
  , Closure
  , expect
  , send
  , monitor
  , receiveWait
  , match
  , ProcessMonitorNotification(..)
  )
import Control.Distributed.Process.Closure 
  ( remotable
  , mkClosure
  , SerializableDict(..)
  , mkStatic
  )
import Control.Distributed.Process.Backend.Azure (Backend)
import Control.Distributed.Process.Backend.Azure.GenericMain 
  ( genericMain
  , ProcessPair(..)
  , RemoteProcess
  )
import qualified Data.ByteString.Lazy as BSL (readFile, writeFile) 

sdictString :: SerializableDict String
sdictString = SerializableDict

ping :: () -> Backend -> Process String 
ping () _backend = do
  mPingServerEnc <- liftIO $ try (BSL.readFile "pingServer.pid")
  case mPingServerEnc of
    Left err -> 
      return $ "Ping server not found: " ++ show (err :: IOException)
    Right pingServerEnc -> do 
      let pingServer = decode pingServerEnc
      pid <- getSelfPid
      monitor pingServer 
      send pingServer pid
      gotReply <- receiveWait 
        [ match (\() -> return True)
        , match (\(ProcessMonitorNotification _ _ _) -> return False)
        ]
      if gotReply
        then return $ "Ping server at " ++ show pingServer ++ " ok"
        else return $ "Ping server at " ++ show pingServer ++ " failure"

pingServer :: () -> Backend -> Process ()
pingServer () _backend = do
  pid <- getSelfPid
  liftIO $ BSL.writeFile "pingServer.pid" (encode pid)
  forever $ do 
    pid <- expect
    send pid ()

remotable ['ping, 'pingServer, 'sdictString]

main :: IO ()
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable "ping" = return $ ProcessPair ($(mkClosure 'ping) ()) putStrLn $(mkStatic 'sdictString)
    callable _      = error "spawnable: unknown"

    spawnable :: String -> IO (RemoteProcess ())
    spawnable "pingServer" = return $ $(mkClosure 'pingServer) () 
    spawnable _            = error "callable: unknown"
