{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImpredicativeTypes  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE TemplateHaskell     #-}

module Main where

import Control.Exception (SomeException, throwIO)
import Control.Distributed.Process hiding (call, expect)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform hiding (__remoteTable)
import Control.Distributed.Process.Platform.Supervisor hiding (start)
import qualified Control.Distributed.Process.Platform.Supervisor as Supervisor
import Control.Distributed.Process.Platform.ManagedProcess.Client (shutdown)
import Control.Distributed.Process.Serializable()
import Control.Monad (void)
import Control.Rematch hiding (expect, match)
import qualified Control.Rematch as Rematch

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.HUnit (Assertion)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils
import qualified Network.Transport as NT

--  start :: RestartStrategy -> [ChildSpec] -> Process ProcessId

expect :: a -> Matcher a -> Process ()
expect a m = liftIO $ Rematch.expect a m

shouldBe :: a -> Matcher a -> Process ()
shouldBe = expect

shouldMatch :: a -> Matcher a -> Process ()
shouldMatch = expect

shouldExitWith :: (Addressable a) => a -> DiedReason -> Process ()
shouldExitWith a r = do
  pid <- resolve a
  d <- receiveWait [ match (\(ProcessMonitorNotification _ _ r') -> return r') ]
  d `shouldBe` equalTo r

ensureProcessIsAlive :: ProcessId -> Process ()
ensureProcessIsAlive pid = do
  result <- isProcessAlive pid
  expect result $ is True

runInTestContext :: LocalNode
                 -> RestartStrategy
                 -> [ChildSpec]
                 -> (ProcessId -> Process ())
                 -> Assertion
runInTestContext node rs cs proc = do
  runProcess node $ Supervisor.start rs cs >>= proc

normalStartStop :: ProcessId -> Process ()
normalStartStop sup = do
  ensureProcessIsAlive sup
  void $ monitor sup
  shutdown sup
  sup `shouldExitWith` DiedNormal

myRemoteTable :: RemoteTable
myRemoteTable = initRemoteTable

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport myRemoteTable
  let withSupervisor = runInTestContext localNode
  return
    [ testGroup "Supervisor Process Behaviour"
       [ testCase "StartStop"
             (withSupervisor (RestartNone defaultLimits) [] normalStartStop)
       ]
    ]

main :: IO ()
main = testMain $ tests

