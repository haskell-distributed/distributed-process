{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()

import Control.Distributed.Process.Extras hiding (__remoteTable, monitor, send)
import qualified Control.Distributed.Process.Extras (__remoteTable)
import Control.Distributed.Process.Extras.Call
import Control.Distributed.Process.Extras.Monitoring
import Control.Distributed.Process.Extras.Time
import Control.Monad (void)
import Control.Rematch hiding (match)
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP()
#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.HUnit (Assertion)
import Test.Framework (Test, testGroup, defaultMain)
import Test.Framework.Providers.HUnit (testCase)
import Network.Transport.TCP
import qualified Network.Transport as NT
import Control.Distributed.Process.Tests.Internal.Utils

testLinkingWithNormalExits :: TestResult DiedReason -> Process ()
testLinkingWithNormalExits result = do
  testPid <- getSelfPid
  pid <- spawnLocal $ do
    worker <- spawnLocal $ do
      "finish" <- expect
      return ()
    linkOnFailure worker
    send testPid worker
    () <- expect
    return ()

  workerPid <- expect :: Process ProcessId
  ref <- monitor workerPid

  send workerPid "finish"
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
              (\_ -> return ())
    ]

  -- by now, the worker is gone, so we can check that the
  -- insulator is still alive and well and that it exits normally
  -- when asked to do so
  ref2 <- monitor pid
  send pid ()

  r <- receiveWait [
      matchIf (\(ProcessMonitorNotification ref2' _ _) -> ref2 == ref2')
              (\(ProcessMonitorNotification _ _ reason) -> return reason)
    ]
  stash result r

testLinkingWithAbnormalExits :: TestResult (Maybe Bool) -> Process ()
testLinkingWithAbnormalExits result = do
  testPid <- getSelfPid
  pid <- spawnLocal $ do
    worker <- spawnLocal $ do
      "finish" <- expect
      return ()

    linkOnFailure worker
    send testPid worker
    () <- expect
    return ()

  workerPid <- expect :: Process ProcessId

  ref <- monitor pid
  kill workerPid "finish"  -- note the use of 'kill' instead of send
  r <- receiveTimeout (asTimeout $ seconds 20) [
      matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
              (\(ProcessMonitorNotification _ _ reason) -> return reason)
    ]
  case r of
    Just (DiedException _) -> stash result $ Just True
    (Just _)               -> stash result $ Just False
    Nothing                -> stash result Nothing

testMonitorNodeDeath :: NT.Transport -> TestResult () -> Process ()
testMonitorNodeDeath transport result = do
    void $ nodeMonitor >> monitorNodes   -- start node monitoring

    nid1 <- getSelfNode
    nid2 <- liftIO $ newEmptyMVar
    nid3 <- liftIO $ newEmptyMVar

    node2 <- liftIO $ newLocalNode transport initRemoteTable
    node3 <- liftIO $ newLocalNode transport initRemoteTable

    -- sending to (nodeId, "ignored") is a short cut to force a connection
    liftIO $ tryForkProcess node2 $ ensureNodeRunning nid2 (nid1, "ignored")
    liftIO $ tryForkProcess node3 $ ensureNodeRunning nid3 (nid1, "ignored")

    NodeUp _ <- expect
    NodeUp _ <- expect

    void $ liftIO $ closeLocalNode node2
    void $ liftIO $ closeLocalNode node3

    NodeDown n1 <- expect
    NodeDown n2 <- expect

    mn1 <- liftIO $ takeMVar nid2
    mn2 <- liftIO $ takeMVar nid3

    [mn1, mn2] `shouldContain` n1
    [mn1, mn2] `shouldContain` n2

    nid4 <- liftIO $ newEmptyMVar
    node4 <- liftIO $ newLocalNode transport initRemoteTable
    void $ liftIO $ runProcess node4 $ do
      us <- getSelfNode
      liftIO $ putMVar nid4 us
      monitorNode nid1 >> return ()

    mn3 <- liftIO $ takeMVar nid4
    NodeUp n3 <- expect
    mn3 `shouldBe` (equalTo n3)

    liftIO $ closeLocalNode node4
    stash result ()

    where
      ensureNodeRunning mvar nid = do
        us <- getSelfNode
        liftIO $ putMVar mvar us
        sendTo nid "connected"

myRemoteTable :: RemoteTable
myRemoteTable = Control.Distributed.Process.Extras.__remoteTable initRemoteTable

multicallTest :: NT.Transport -> Assertion
multicallTest transport =
  do node1 <- newLocalNode transport myRemoteTable
     tryRunProcess node1 $
       do pid1 <- whereisOrStart "server1" server1
          _ <- whereisOrStart "server2" server2
          pid2 <- whereisOrStart "server2" server2
          tag <- newTagPool

          -- First test: expect positives answers from both processes
          tag1 <- getTag tag
          result1 <- multicall [pid1,pid2] mystr tag1 infiniteWait
          case result1 of
            [Just reversed, Just doubled] |
                 reversed == reverse mystr && doubled == mystr ++ mystr -> return ()
            _ -> error "Unmatched"

          -- Second test: First process works, second thread throws an exception
          tag2 <- getTag tag
          [Just 10, Nothing] <- multicall [pid1,pid2] (5::Int) tag2 infiniteWait :: Process [Maybe Int]

          -- Third test: First process exceeds time limit, second process is still dead
          tag3 <- getTag tag
          [Nothing, Nothing] <- multicall [pid1,pid2] (23::Int) tag3 (Just 1000000) :: Process [Maybe Int]
          return ()
    where server1 = receiveWait [callResponse (\str -> mention (str::String) (return (reverse str,())))]  >>
                    receiveWait [callResponse (\i -> mention (i::Int) (return (i*2,())))] >>
                    receiveWait [callResponse (\i -> liftIO (threadDelay 2000000) >> mention (i::Int) (return (i*10,())))]
          server2 = receiveWait [callResponse (\str -> mention (str::String) (return (str++str,())))] >>
                    receiveWait [callResponse (\i -> error "barf" >> mention (i::Int) (return (i :: Int,())))]
          mystr = "hello"
          mention :: a -> b -> b
          mention _a b = b



--------------------------------------------------------------------------------
-- Utilities and Plumbing                                                     --
--------------------------------------------------------------------------------

tests :: NT.Transport -> LocalNode  -> [Test]
tests transport localNode = [
    testGroup "Linking Tests" [
        testCase "testLinkingWithNormalExits"
                 (delayedAssertion
                  "normal exit should not terminate the caller"
                  localNode DiedNormal testLinkingWithNormalExits)
      , testCase "testLinkingWithAbnormalExits"
                 (delayedAssertion
                  "abnormal exit should terminate the caller"
                  localNode (Just True) testLinkingWithAbnormalExits)
      ],
    testGroup "Call/RPC" [
        testCase "multicallTest" (multicallTest transport)
      ],
    testGroup "Node Monitoring" [
        testCase "Death Notifications"
          (delayedAssertion
           "subscribers should both have received NodeDown twice"
           localNode () (testMonitorNodeDeath transport))
      ]
  ]

primitivesTests :: NT.Transport -> IO [Test]
primitivesTests transport = do
  localNode <- newLocalNode transport initRemoteTable
  let testData = tests transport localNode
  return testData

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                     "127.0.0.1" "0" defaultTCPParameters
  testData <- builder transport
  defaultMain testData

main :: IO ()
main = testMain $ primitivesTests
