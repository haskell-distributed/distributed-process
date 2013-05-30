{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImpredicativeTypes  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE TemplateHaskell     #-}

module Main where

import Control.Exception (Exception, SomeException, throwIO)
import Control.Distributed.Process hiding (call, expect)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform hiding (__remoteTable)
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
import Control.Distributed.Process.Platform.Internal.Primitives (forever')
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

import Test.HUnit (Assertion, assertFailure)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils hiding (waitForExit)
import qualified Network.Transport as NT

-- test utilities

expect :: a -> Matcher a -> Process ()
expect a m = liftIO $ Rematch.expect a m

shouldBe :: a -> Matcher a -> Process ()
shouldBe = expect

shouldMatch :: a -> Matcher a -> Process ()
shouldMatch = expect

shouldExitWith :: (Addressable a) => a -> DiedReason -> Process ()
shouldExitWith a r = do
  _ <- resolve a
  -- monitor pid
  d <- receiveWait [ match (\(ProcessMonitorNotification _ _ r') -> return r') ]
  d `shouldBe` equalTo r

tempWorker :: Closure (Process ()) -> ChildSpec
tempWorker clj =
  ChildSpec
  {
    childKey     = "temp-worker"
  , childType    = Worker
  , childRestart = Restart Temporary
  , childRun     = clj
  }

transientWorker :: Closure (Process ()) -> ChildSpec
transientWorker clj =
  ChildSpec
  {
    childKey     = "transient-worker"
  , childType    = Worker
  , childRestart = Restart Transient
  , childRun     = clj
  }

intrinsicWorker :: Closure (Process ()) -> ChildSpec
intrinsicWorker clj =
  ChildSpec
  {
    childKey     = "intrinsic-worker"
  , childType    = Worker
  , childRestart = Restart Intrinsic
  , childRun     = clj
  }

permChild :: Closure (Process ()) -> ChildSpec
permChild clj =
  ChildSpec
  {
    childKey     = "perm-child"
  , childType    = Worker
  , childRestart = Restart Permanent
  , childRun     = clj
  }

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
  runProcess node $ do
    sup <- Supervisor.start rs cs
    (proc sup) `finally` (kill sup "goodbye")

exitIgnore :: Process ()
exitIgnore = liftIO $ throwIO ChildInitIgnore

noOp :: Process ()
noOp = return ()

blockIndefinitely :: Process ()
blockIndefinitely = runTestProcess noOp

verifyChildWasRestarted :: ChildKey -> ProcessId -> ProcessId -> Process ()
verifyChildWasRestarted key pid sup = do
  void $ waitForExit pid
  cSpec <- lookupChild sup key
  -- TODO: handle (ChildRestarting _) too!
  case cSpec of
    Just (ref, _) -> do
      Just pid' <- resolve ref
      expect pid' $ isNot $ equalTo pid
    _ -> do
      liftIO $ assertFailure $ "unexpected child ref: " ++ (show cSpec)

verifyChildWasNotRestarted :: ChildKey -> ProcessId -> ProcessId -> Process ()
verifyChildWasNotRestarted key pid sup = do
  void $ waitForExit pid
  cSpec <- lookupChild sup key
  case cSpec of
    Just (ChildStopped, _) -> return ()
    _ -> liftIO $ assertFailure $ "unexpected child ref: " ++ (show cSpec)

verifyTempChildWasRemoved :: ProcessId -> ProcessId -> Process ()
verifyTempChildWasRemoved pid sup = do
  void $ waitForExit pid
  cSpec <- lookupChild sup "temp-worker"
  expect cSpec isNothing

waitForExit :: ProcessId -> Process DiedReason
waitForExit pid = do
  monitor pid >>= waitForDown

waitForDown :: MonitorRef -> Process DiedReason
waitForDown ref =
  receiveWait [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                        (\(ProcessMonitorNotification _ _ dr) -> return dr) ]

$(remotable ['exitIgnore, 'noOp, 'blockIndefinitely])

-- test cases start here...

normalStartStop :: ProcessId -> Process ()
normalStartStop sup = do
  ensureProcessIsAlive sup
  void $ monitor sup
  shutdown sup
  sup `shouldExitWith` DiedNormal

configuredTemporaryChildExitsWithIgnore ::
  (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion) -> Assertion
configuredTemporaryChildExitsWithIgnore withSupervisor =
  let spec = tempWorker $(mkStaticClosure 'exitIgnore) in do
    withSupervisor restartOne [spec] verifyExit
  where
    verifyExit :: ProcessId -> Process ()
    verifyExit sup = do
--      sa <- isProcessAlive sup
      child <- lookupChild sup "temp-worker"
      case child of
        Nothing       -> return () -- the child exited and was removed ok
        Just (ref, _) -> do
          Just pid <- resolve ref
          verifyTempChildWasRemoved pid sup

configuredNonTemporaryChildExitsWithIgnore ::
  (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion) -> Assertion
configuredNonTemporaryChildExitsWithIgnore withSupervisor =
  let spec = transientWorker $(mkStaticClosure 'exitIgnore) in do
    withSupervisor restartOne [spec] $ verifyExit spec
  where
    verifyExit :: ChildSpec -> ProcessId -> Process ()
    verifyExit spec sup = do
      sleep $ milliSeconds 100  -- just make sure our super has seen the EXIT signal
      child <- lookupChild sup (childKey spec)
      case child of
        Nothing           -> liftIO $ assertFailure $ "lost non-temp spec!"
        Just (ref, spec') -> do
          rRef <- resolve ref
          maybe (return DiedNormal) waitForExit rRef
          cSpec <- lookupChild sup (childKey spec')
          case cSpec of
            Just (ChildStopped, _) -> return ()
            _                      -> do
              liftIO $ assertFailure $ "unexpected lookup: " ++ (show cSpec)

startTemporaryChildExitsWithIgnore :: ProcessId -> Process ()
startTemporaryChildExitsWithIgnore sup =
  -- if a temporary child exits with "ignore" then we must
  -- have deleted its specification from the supervisor
  let spec = tempWorker $(mkStaticClosure 'exitIgnore) in do
    ChildAdded ref <- startChild sup spec
    Just pid <- resolve ref
    verifyTempChildWasRemoved pid sup

startNonTemporaryChildExitsWithIgnore :: ProcessId -> Process ()
startNonTemporaryChildExitsWithIgnore sup =
  let spec = transientWorker $(mkStaticClosure 'exitIgnore) in do
    ChildAdded ref <- startChild sup spec
    Just pid <- resolve ref
    void $ waitForExit pid
    sleep $ milliSeconds 250
    cSpec <- lookupChild sup (childKey spec)
    case cSpec of
      Just (ChildStopped, _) -> return ()
      _                      -> do
        liftIO $ assertFailure $ "unexpected lookup: " ++ (show cSpec)

addChildWithoutRestart :: ProcessId -> Process ()
addChildWithoutRestart sup =
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely) in do
    response <- addChild sup spec
    response `shouldBe` equalTo (ChildAdded ChildStopped)

addDuplicateChild :: ProcessId -> Process ()
addDuplicateChild sup =
  let spec =
        transientWorker $(mkStaticClosure 'blockIndefinitely) in do
    response <- addChild sup spec
    response `shouldBe` equalTo (ChildAdded ChildStopped)
    Just (ref, _) <- lookupChild sup "transient-worker"
    dup <- addChild sup spec
    dup `shouldBe` equalTo (ChildFailedToStart $ StartFailureDuplicateChild ref)

startDuplicateChild :: ProcessId -> Process ()
startDuplicateChild sup =
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely) in do
    response <- addChild sup spec
    response `shouldBe` equalTo (ChildAdded ChildStopped)
    Just (ref, _) <- lookupChild sup "transient-worker"
    dup <- startChild sup spec
    dup `shouldBe` equalTo (ChildFailedToStart $ StartFailureDuplicateChild ref)

deleteExistingChild :: ProcessId -> Process ()
deleteExistingChild sup =
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely) in do
    (ChildAdded ref) <- startChild sup spec
    result <- deleteChild sup "transient-worker"
    result `shouldBe` equalTo (ChildNotStopped ref)

deleteStoppedTempChild :: ProcessId -> Process ()
deleteStoppedTempChild sup = do
  let spec = tempWorker $(mkStaticClosure 'blockIndefinitely)
  ChildAdded ref <- startChild sup spec
  Just pid <- resolve ref
  testProcessStop pid
  -- child needs to be stopped
  waitForExit pid
  result <- deleteChild sup (childKey spec)
  result `shouldBe` equalTo ChildNotFound

deleteStoppedChild :: ProcessId -> Process ()
deleteStoppedChild sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
  ChildAdded ref <- startChild sup spec
  Just pid <- resolve ref
  testProcessStop pid
  -- child needs to be stopped
  waitForExit pid
  result <- deleteChild sup (childKey spec)
  result `shouldBe` equalTo ChildDeleted

permanentChildrenAlwaysRestart :: ProcessId -> Process ()
permanentChildrenAlwaysRestart sup = do
  let spec = permChild $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref) <- startChild sup spec
  Just pid <- resolve ref
  testProcessStop pid  -- a normal stop should *still* trigger a restart
  verifyChildWasRestarted (childKey spec) pid sup

temporaryChildrenNeverRestart :: ProcessId -> Process ()
temporaryChildrenNeverRestart sup = do
  let spec = tempWorker $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref) <- startChild sup spec
  Just pid <- resolve ref
  kill pid "bye bye"
  verifyTempChildWasRemoved pid sup

transientChildrenNormalExit :: ProcessId -> Process ()
transientChildrenNormalExit sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref) <- startChild sup spec
  Just pid <- resolve ref
  testProcessStop pid
  verifyChildWasNotRestarted (childKey spec) pid sup

transientChildrenAbnormalExit :: ProcessId -> Process ()
transientChildrenAbnormalExit sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref) <- startChild sup spec
  Just pid <- resolve ref
  kill pid "bye bye"
  verifyChildWasRestarted (childKey spec) pid sup

transientChildrenExitShutdown :: ProcessId -> Process ()
transientChildrenExitShutdown sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref) <- startChild sup spec
  Just pid <- resolve ref
  exit pid ExitShutdown
  verifyChildWasNotRestarted (childKey spec) pid sup

intrinsicChildrenAbnormalExit :: ProcessId -> Process ()
intrinsicChildrenAbnormalExit sup = do
  let spec = intrinsicWorker $(mkStaticClosure 'blockIndefinitely)
  ChildAdded ref <- startChild sup spec
  Just pid <- resolve ref
  kill pid "bye bye"
  verifyChildWasRestarted (childKey spec) pid sup

intrinsicChildrenNormalExit :: ProcessId -> Process ()
intrinsicChildrenNormalExit sup = do
  let spec = intrinsicWorker $(mkStaticClosure 'blockIndefinitely)
  ChildAdded ref <- startChild sup spec
  Just pid <- resolve ref
  testProcessStop pid
  reason <- waitForExit sup
  expect reason $ equalTo DiedNormal

permanentChildExceedsRestartsIntensity ::
  (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion) -> Assertion
permanentChildExceedsRestartsIntensity withSupervisor = do
  let spec = permChild $(mkStaticClosure 'noOp)  -- child just keeps exiting
  let strategy = RestartOne $ limit (maxRestarts 10) (seconds 1)
  withSupervisor strategy [spec] $ \sup -> do
    ref <- monitor sup
    void $ startChild sup spec
    reason <- waitForDown ref
    expect reason $ equalTo $
                      DiedException $ "exit-from=" ++ (show sup) ++
                                      ", reason=ReachedMaxRestartIntensity"

-- remote table definition and main

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

tests :: NT.Transport -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport myRemoteTable
  let withSupervisor = runInTestContext localNode
  return
    [ testGroup "Supervisor Processes"
      [
          testGroup "Starting And Adding Children"
          [
            testCase "Normal (Managed Process) Supervisor Start Stop"
                (withSupervisor restartOne [] normalStartStop)
          , testCase "Add Child Without Starting"
                (withSupervisor restartOne [] addChildWithoutRestart)
          , testCase "Add Duplicate Child"
                (withSupervisor restartOne [] addDuplicateChild)
          , testCase "Start Duplicate Child"
                (withSupervisor restartOne [] startDuplicateChild)
          , testCase "Started Temporary Child Exits With Ignore"
                (withSupervisor restartOne [] startTemporaryChildExitsWithIgnore)
          , testCase "Configured Temporary Child Exits With Ignore"
                (configuredTemporaryChildExitsWithIgnore withSupervisor)
          , testCase "Started Non-Temporary Child Exits With Ignore"
                (withSupervisor restartOne [] startNonTemporaryChildExitsWithIgnore)
          , testCase "Configured Non-Temporary Child Exits With Ignore"
                (configuredNonTemporaryChildExitsWithIgnore withSupervisor)
          ]
        , testGroup "Terminating And Deleting Children"
          [
            testCase "Delete Existing Child Fails"
                (withSupervisor restartOne [] deleteExistingChild)
          , testCase "Delete Stopped Temporary Child (Doesn't Exist)"
                (withSupervisor restartOne [] deleteStoppedTempChild)
          , testCase "Delete Stopped Child Succeeds"
                (withSupervisor restartOne [] deleteStoppedChild)
          ]
        , testGroup "Restarting Children"
          [
            testCase "Permanent Children Always Restart"
                (withSupervisor restartOne [] permanentChildrenAlwaysRestart)
          , testCase "Temporary Children Never Restart"
                (withSupervisor restartOne [] temporaryChildrenNeverRestart)
          , testCase "Transient Children Do Not Restart When Exiting Normally"
                (withSupervisor restartOne [] transientChildrenNormalExit)
          , testCase "Transient Children Do Restart When Exiting Abnormally"
                (withSupervisor restartOne [] transientChildrenAbnormalExit)
          , testCase "ExitShutdown Is Considered Normal"
                (withSupervisor restartOne [] transientChildrenExitShutdown)
          , testCase "Intrinsic Children Do Restart When Exiting Abnormally"
                (withSupervisor restartOne [] intrinsicChildrenAbnormalExit)
          , testCase "Intrinsic Children Cause Supervisor Exits When Exiting Normally"
                (withSupervisor restartOne [] intrinsicChildrenNormalExit)
--          , testCase "Explicit Restart Of Running Child Fails"
--                (withSupervisor restartOne [] explicitRestartRunningChild)
          ]
        , testGroup "Restart Intensity / Delayed Restarts"
          [
            testCase "Permanent Child Exceeds Restart Limits"
                (permanentChildExceedsRestartsIntensity withSupervisor)
          ]
      ]
    ]

main :: IO ()
main = testMain $ tests

