{-# LANGUAGE OverloadedStrings #-}
module Main where

import TEST_SUITE_MODULE (tests)
import qualified TEST_SUITE_MODULE as Remote (remoteTable)
import Control.Distributed.Process (NodeId(..))
import Control.Distributed.Process.Node (initRemoteTable, newLocalNode)
import Control.Monad (unless)
import Control.Monad.Catch (throwM)
import Network.Transport (EndPointAddress(..))
import Network.Transport.TCP
  ( createTransport
  , defaultTCPParameters
  , defaultTCPAddr
  , TCPParameters(..)
  )
import Test.Framework (defaultMainWithArgs)
import System.Environment (lookupEnv, getArgs)
import System.Exit (ExitCode(ExitSuccess))
import System.IO
{-
import System.Process.Typed (shell, runProcess, withProcess_, ProcessConfig)

buildTestNodePConfig :: ProcessConfig () () ()
buildTestNodePConfig = "stack build distributed-process-tests:RemoteHost"

runTestNodePConfig :: ProcessConfig () () ()
runTestNodePConfig = "stack run distributed-process-tests:RemoteHost"

spawnTestNode :: IO ()
spawnTestNode = do
  err <- runProcess buildTestNodePConfig
  unless (err == ExitSuccess) $ error "Unable to build RemoteHost"
  withProcess_ runTestNodePConfig $ const runTestsWithNodePresent

-}

spawnTestNode :: IO ()
spawnTestNode = error "Unsupported Configuration"

runTestsWithNodePresent :: IO ()
runTestsWithNodePresent = do
  nt <- createTransport (defaultTCPAddr "127.0.0.1" "10517")
                        (defaultTCPParameters { tcpNoDelay = True })
  let remoteId = NodeId $ EndPointAddress "127.0.0.1:10516:0"
  case nt of
    Right transport -> do node  <- newLocalNode transport $ Remote.remoteTable initRemoteTable
                          args  <- getArgs
                          suite <- tests node remoteId
                          defaultMainWithArgs suite args
    _               -> error "Unable to initialise network-transport"

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  env <- lookupEnv "DISTRIBUTED_PROCESS_TEST_NODE"
  -- ctx <- lookupEnv "DISTRIBUTED_PROCESS_SPAWN_NODE"
  case env of
    Nothing -> putStrLn errorNoNode >> error errorNoNode
    Just _  -> runTestsWithNodePresent
    -- (Nothing, Just _)  -> spawnTestNode
  where
    errorNoNode = "NO TEST NODE PRESENT"
