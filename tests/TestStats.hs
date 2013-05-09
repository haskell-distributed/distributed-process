{-# LANGUAGE DeriveDataTypeable        #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
module Main where

import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Node
  ( forkProcess
  , newLocalNode
  , initRemoteTable
  , closeLocalNode
  , LocalNode)
import Data.Binary()
import Data.Typeable()
import Network.Transport.TCP
import Prelude hiding (catch, log)
import Test.Framework
  ( Test
  , defaultMain
  , testGroup
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
  getProcessInfo pid >>= stash result

testLocalLiveProcessInfo :: TestResult Bool -> Process ()
testLocalLiveProcessInfo result = do
  self <- getSelfPid
  node <- getSelfNode
  register "foobar" self

  mon <- liftIO $ newEmptyMVar
  -- TODO: we can't get the mailbox's length
  -- mapM (send self) ["hello", "there", "mr", "process"]
  pid <- spawnLocal $ do
       link self
       mRef <- monitor self
       stash mon mRef
       "die" <- expect
       return ()

  monRef <- liftIO $ takeMVar mon

  mpInfo <- getProcessInfo self
  case mpInfo of
    Nothing -> stash result False
    Just p  -> verifyPInfo p pid monRef node
  where verifyPInfo :: ProcessInfo
                    -> ProcessId
                    -> MonitorRef
                    -> NodeId
                    -> Process ()
        verifyPInfo pInfo pid mref node =
          stash result $ infoNode pInfo     == node           &&
                         infoLinks pInfo    == [pid]          &&
                         infoMonitors pInfo == [(pid, mref)]  &&
--                         infoMessageQueueLength pInfo == Just 4 &&
                         infoRegisteredNames pInfo == ["foobar"]

testRemoteLiveProcessInfo :: LocalNode -> Assertion
testRemoteLiveProcessInfo node1 = do
  serverAddr <- liftIO $ newEmptyMVar :: IO (MVar ProcessId)
  liftIO $ launchRemote serverAddr
  serverPid <- liftIO $ takeMVar serverAddr
  withActiveRemote node1 $ \result -> do
    self <- getSelfPid
    link serverPid
    -- our send op shouldn't overtake link or monitor requests AFAICT
    -- so a little table tennis should get us synchronised properly
    send serverPid (self, "ping")
    "pong" <- expect
    pInfo <- getProcessInfo serverPid
    stash result $ pInfo /= Nothing
  where
    launchRemote :: MVar ProcessId -> IO ()
    launchRemote locMV = do
        node2 <- liftIO $ mkNode "8082"
        _ <- liftIO $ forkProcess node2 $ do
            self <- getSelfPid
            liftIO $ putMVar locMV self
            _ <- receiveWait [
                  match (\(pid, "ping") -> send pid "pong")
                ]
            "stop" <- expect
            return ()
        return ()

    withActiveRemote :: LocalNode
                     -> ((TestResult Bool -> Process ()) -> Assertion)
    withActiveRemote n = do
      a <- delayedAssertion "getProcessInfo remotePid failed" n True
      return a

tests :: LocalNode -> IO [Test]
tests node1 = do
  return [
    testGroup "Process Info" [
        testCase "testLocalDeadProcessInfo"
            (delayedAssertion
             "expected dead process-info to be ProcessInfoNone"
             node1 (Nothing) testLocalDeadProcessInfo)
      , testCase "testLocalLiveProcessInfo"
            (delayedAssertion
             "expected process-info to be correctly populated"
             node1 True testLocalLiveProcessInfo)
      , testCase "testRemoveLiveProcessInfo"
                 (testRemoteLiveProcessInfo node1)
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
