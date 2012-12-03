{-# LANGUAGE TemplateHaskell #-}

import System.Environment (getArgs)
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
import qualified Data.ByteString.Lazy as BSL (readFile, writeFile)

pingServer :: () -> Backend -> Process ()
pingServer () _backend = do
  us <- getSelfPid
  liftIO $ BSL.writeFile "pingServer.pid" (encode us)
  forever $ do
    them <- expect
    send them ()

pingClientRemote :: () -> Backend -> Process ()
pingClientRemote () _backend = do
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

remotable ['pingClientRemote, 'pingServer]

pingClientLocal :: LocalProcess ()
pingClientLocal = localExpect >>= liftIO . putStrLn

main :: IO ()
main = do
  args <- getArgs
  case args of
    "onvm":args' ->
      -- Pass execution to 'onVmMain' if we are running on the VM
      onVmMain __remoteTable args'

    "list":sid:x509:pkey:_ -> do
      -- List all available cloud services
      -- (useful, but not strictly necessary for the example)
      params <- defaultAzureParameters sid x509 pkey
      css <- cloudServices (azureSetup params)
      mapM_ print css

    cmd:sid:x509:pkey:user:cloudService:virtualMachine:port:_ -> do
      -- Initialize the backend and find the right VM
      params <- defaultAzureParameters sid x509 pkey
      let params' = params { azureSshUserName = user }
      backend <- initializeBackend params' cloudService
      Just vm <- findNamedVM backend virtualMachine

      -- The same binary can behave as the client or the server,
      -- depending on the command line arguments
      case cmd of
        "server" -> do
          pid <- spawnOnVM backend vm port ($(mkClosure 'pingServer) ())
          putStrLn $ "Ping server started at " ++ show pid
        "client" ->
          callOnVM backend vm port $
            ProcessPair ($(mkClosure 'pingClientRemote) ())
                        pingClientLocal
