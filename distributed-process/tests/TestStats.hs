{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import Prelude hiding (catch)
import qualified Network.Transport as NT
import Test.Framework
  ( Test
  , defaultMain
  , testGroup
  )
import Network.Transport.TCP
import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( forkProcess
  , newLocalNode
  , initRemoteTable
  , closeLocalNode
  , LocalNode)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Test.HUnit (Assertion)
import Test.HUnit.Base (assertBool)
import Test.Framework.Providers.HUnit (testCase)

-- these utilities have been cribbed from distributed-process-platform
-- we should really find a way to share them...

-- | A mutable cell containing a test result.
type TestResult a = MVar a

delayedAssertion :: (Eq a) => String -> LocalNode -> a ->
                    (TestResult a -> Process ()) -> Assertion
delayedAssertion note localNode expected testProc = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ testProc result
  assertComplete note result expected

assertComplete :: (Eq a) => String -> MVar a -> a -> IO ()
assertComplete msg mv a = do
  b <- takeMVar mv
  assertBool msg (a == b)

stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

------

testLocalDeadProcessInfo :: TestResult (Maybe ProcessInfo) -> Process ()
testLocalDeadProcessInfo result = do
  pid <- spawnLocal $ do "finish" <- expect; return ()
  mref <- monitor pid
  send pid "finish"
  _ <- receiveWait [
      matchIf (\(ProcessMonitorNotification ref' pid' r) ->
                    ref' == mref && pid' == pid && r == DiedNormal)
              (\p -> return p)
    ]
  say "waiting for process info...."
  getProcessInfo pid >>= stash result

tests :: LocalNode -> IO [Test]
tests node1 = do
  return [
    testGroup "Process Info" [
      testCase "testLocalDeadProcessInfo"
            (delayedAssertion
             "expected dead process-info to be ProcessInfoNone"
             node1 (Nothing) testLocalDeadProcessInfo)
    ] ]

mkNode :: String -> IO LocalNode
mkNode port = do
  Right (transport1, _) <- createTransportExposeInternals
                                    "127.0.0.1" port defaultTCPParameters
  newLocalNode transport1 initRemoteTable

main :: IO ()
main = do
  node1 <- mkNode "8081"
  testData <- tests node1
  defaultMain testData
  closeLocalNode node1
  return ()

