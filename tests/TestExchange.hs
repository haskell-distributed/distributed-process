{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import Control.Distributed.Process hiding (monitor)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform
  ( Routable(..)
  , Resolvable(..)
  , Observable(..)
  )

import qualified Control.Distributed.Process.Platform (__remoteTable)
import Control.Distributed.Process.Platform.Execution.EventManager hiding (start)
import qualified Control.Distributed.Process.Platform.Execution.EventManager as EventManager
  ( start
  , monitor
  )
-- import Control.Distributed.Process.Platform.Execution.Exchange.Broadcast (monitor)
import Control.Distributed.Process.Platform.Test
-- import Control.Distributed.Process.Platform.Time
-- import Control.Distributed.Process.Platform.Timer
-- import Control.Monad (forM_)
import Control.Rematch (equalTo)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop)
#endif

import Data.Maybe (catMaybes)
import qualified Network.Transport as NT
import Test.Framework as TF (testGroup, Test)
import Test.Framework.Providers.HUnit
import TestUtils

testIt :: TestResult Bool -> Process ()
testIt result = do
  (sp, rp) <- newChan
  em <- EventManager.start
  EventManager.monitor em
  pid <- addHandler em (myHandler sp) ()  -- cast message
  link pid

  notify em ("hello", "event", "manager") -- cast message
  r <- receiveTimeout 2000000 [
      matchChan rp return
    , match (\(ProcessMonitorNotification _ _ r) -> do
                (liftIO $ putStrLn (show r)) >> die "FUCK")
    ]
  case r of
    Nothing -> do
      stash result False
      mPid <- resolve em
      case mPid of
        Just p -> liftIO . putStrLn . show =<< getProcessInfo p
        Nothing -> return ()
    Just ("hello", "event", "manager") -> stash result True

myHandler :: SendPort (String, String, String)
          -> ()
          -> (String, String, String)
          -> Process ()
myHandler sp s m@(_, _, _) = do
  liftIO $ putStrLn "running handler...."
  sendChan sp m >> return s

myRemoteTable :: RemoteTable
myRemoteTable =
  Control.Distributed.Process.Platform.__remoteTable initRemoteTable

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport myRemoteTable
  return [
        testGroup "Event Manager"
        [
          testCase "Simple Event Handlers"
          (delayedAssertion
           "Expected the handler to run" localNode True testIt)
--        , testCase "Simple Event Handlers 2"
--          (delayedAssertion
--           "Expected the handler to run" localNode True testIt)
        ]
    ]
  where
    inputs = ("hello", 10 :: Int, True)

main :: IO ()
main = testMain $ tests

