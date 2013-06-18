{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

-- NOTICE: Some of these tests are /unsafe/, and will fail intermittently, since
-- they rely on ordering constraints which the Cloud Haskell runtime does not
-- guarantee.

module Main where

import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , putMVar
  , takeMVar
  )
import qualified Control.Exception as Ex
import Control.Exception (throwIO)
import Control.Distributed.Process hiding (call, monitor)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform hiding (__remoteTable)
-- import Control.Distributed.Process.Platform as Alt (monitor)
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
import Control.Distributed.Process.Platform.Supervisor hiding (start)
import qualified Control.Distributed.Process.Platform.Supervisor as Supervisor
import Control.Distributed.Process.Platform.ManagedProcess.Client (shutdown)
import Control.Distributed.Process.Serializable()
import Control.Distributed.Static (staticLabel)
import Control.Monad (void, forM_, forM)
import Control.Rematch
  ( equalTo
  , is
  , isNot
  , isNothing
  , isJust
  )

import Data.ByteString.Lazy (empty)
import Data.Maybe (catMaybes)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.HUnit (Assertion, assertFailure)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils hiding (waitForExit)
import qualified Network.Transport as NT

-- test utilities

expectedExitReason :: ProcessId -> String
expectedExitReason sup = "killed-by=" ++ (show sup) ++
                         ",reason=TerminatedBySupervisor"

defaultWorker :: Closure (Process ()) -> ChildSpec
defaultWorker clj =
  ChildSpec
  {
    childKey     = ""
  , childType    = Worker
  , childRestart = Temporary
  , childStop    = TerminateImmediately
  , childRun     = clj
  , childRegName = Nothing
  }

tempWorker :: Closure (Process ()) -> ChildSpec
tempWorker clj =
  (defaultWorker clj)
  {
    childKey     = "temp-worker"
  , childRestart = Temporary
  }

transientWorker :: Closure (Process ()) -> ChildSpec
transientWorker clj =
  (defaultWorker clj)
  {
    childKey     = "transient-worker"
  , childRestart = Transient
  }

intrinsicWorker :: Closure (Process ()) -> ChildSpec
intrinsicWorker clj =
  (defaultWorker clj)
  {
    childKey     = "intrinsic-worker"
  , childRestart = Intrinsic
  }

permChild :: Closure (Process ()) -> ChildSpec
permChild clj =
  (defaultWorker clj)
  {
    childKey     = "perm-child"
  , childRestart = Permanent
  }

ensureProcessIsAlive :: ProcessId -> Process ()
ensureProcessIsAlive pid = do
  result <- isProcessAlive pid
  expectThat result $ is True

runInTestContext :: LocalNode
                 -> MVar ()
                 -> RestartStrategy
                 -> [ChildSpec]
                 -> (ProcessId -> Process ())
                 -> Assertion
runInTestContext node lock rs cs proc = do
  Ex.bracket (takeMVar lock) (putMVar lock) $ \() -> runProcess node $ do
    sup <- Supervisor.start rs cs
    (proc sup) `finally` (kill sup "goodbye")

verifyChildWasRestarted :: ChildKey -> ProcessId -> ProcessId -> Process ()
verifyChildWasRestarted key pid sup = do
  void $ waitForExit pid
  cSpec <- lookupChild sup key
  -- TODO: handle (ChildRestarting _) too!
  case cSpec of
    Just (ref, _) -> do
      Just pid' <- resolve ref
      expectThat pid' $ isNot $ equalTo pid
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
  expectThat cSpec isNothing

waitForExit :: ProcessId -> Process DiedReason
waitForExit pid = do
  monitor pid >>= waitForDown

waitForDown :: Maybe MonitorRef -> Process DiedReason
waitForDown Nothing    = error "invalid mref"
waitForDown (Just ref) =
  receiveWait [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                        (\(ProcessMonitorNotification _ _ dr) -> return dr) ]

drainChildren :: [Child] -> ProcessId -> Process ()
drainChildren children expected = do
  -- Receive all pids then verify they arrived in the correct order.
  -- Any out-of-order messages (such as ProcessMonitorNotification) will
  -- violate the invariant asserted below, and fail the test case
  pids <- forM children $ \_ -> expect :: Process ProcessId
  let first' = head pids
  Just exp' <- resolve expected
  -- however... we do allow for the scheduler and accept `head $ tail pids` in
  -- lieu of the correct result, since when there are multiple senders we have
  -- no causal guarnatee
  if first' /= exp'
     then let second' = head $ tail pids in second' `shouldBe` equalTo exp'
     else first' `shouldBe` equalTo exp'

exitIgnore :: Process ()
exitIgnore = liftIO $ throwIO ChildInitIgnore

noOp :: Process ()
noOp = return ()

blockIndefinitely :: Process ()
blockIndefinitely = runTestProcess noOp

notifyMe :: ProcessId -> Process ()
notifyMe me = getSelfPid >>= send me >> obedient

sleepy :: Process ()
sleepy = (sleepFor 5 Minutes)
           `catchExit` (\_ (_ :: ExitReason) -> return ()) >> sleepy

obedient :: Process ()
obedient = (sleepFor 5 Minutes)
           {- supervisor inserts handlers that act like we wrote:
             `catchExit` (\_ (r :: ExitReason) -> do
                             case r of
                               ExitShutdown -> return ()
                               _ -> die r)
           -}

$(remotable [ 'exitIgnore
            , 'noOp
            , 'blockIndefinitely
            , 'sleepy
            , 'obedient
            , 'notifyMe])

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
      sleep $ milliSeconds 100  -- make sure our super has seen the EXIT signal
      child <- lookupChild sup (childKey spec)
      case child of
        Nothing           -> liftIO $ assertFailure $ "lost non-temp spec!"
        Just (ref, spec') -> do
          rRef <- resolve ref
          maybe (return DiedNormal) waitForExit rRef
          cSpec <- lookupChild sup (childKey spec')
          case cSpec of
            Just (ChildStartIgnored, _) -> return ()
            _                           -> do
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
      Just (ChildStartIgnored, _) -> return ()
      _                      -> do
        liftIO $ assertFailure $ "unexpected lookup: " ++ (show cSpec)

addChildWithoutRestart :: ProcessId -> Process ()
addChildWithoutRestart sup =
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely) in do
    response <- addChild sup spec
    response `shouldBe` equalTo (ChildAdded ChildStopped)

setupChild :: ProcessId -> Process (ChildRef, ChildSpec)
setupChild sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
  response <- addChild sup spec
  response `shouldBe` equalTo (ChildAdded ChildStopped)
  Just child <- lookupChild sup "transient-worker"
  return child

addDuplicateChild :: ProcessId -> Process ()
addDuplicateChild sup = do
  (ref, spec) <- setupChild sup
  dup <- addChild sup spec
  dup `shouldBe` equalTo (ChildFailedToStart $ StartFailureDuplicateChild ref)

startDuplicateChild :: ProcessId -> Process ()
startDuplicateChild sup = do
  (ref, spec) <- setupChild sup
  dup <- startChild sup spec
  dup `shouldBe` equalTo (ChildFailedToStart $ StartFailureDuplicateChild ref)

startBadClosure :: ProcessId -> Process ()
startBadClosure sup = do
  let spec = tempWorker (closure (staticLabel "non-existing") empty)
  child <- startChild sup spec
  child `shouldBe` equalTo
    (ChildFailedToStart $ StartFailureBadClosure
       "user error (Could not resolve closure: Invalid static label 'non-existing')")

configuredBadClosure ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
configuredBadClosure withSupervisor = do
  let spec = permChild (closure (staticLabel "non-existing") empty)
  -- we make sure we don't hit the supervisor's limits
  let strategy = RestartOne $ limit (maxRestarts 500000000) (milliSeconds 1)
  withSupervisor strategy [spec] $ \sup -> do
--    ref <- monitor sup
    children <- (listChildren sup)
    let specs = map fst children
    expectThat specs $ equalTo []

deleteExistingChild :: ProcessId -> Process ()
deleteExistingChild sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
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
  expectThat reason $ equalTo DiedNormal

explicitRestartRunningChild :: ProcessId -> Process ()
explicitRestartRunningChild sup = do
  let spec = tempWorker $(mkStaticClosure 'blockIndefinitely)
  ChildAdded ref <- startChild sup spec
  result <- restartChild sup (childKey spec)
  expectThat result $ equalTo $ ChildRestartFailed (StartFailureAlreadyRunning ref)

explicitRestartUnknownChild :: ProcessId -> Process ()
explicitRestartUnknownChild sup = do
  result <- restartChild sup "unknown-id"
  expectThat result $ equalTo ChildRestartUnknownId

explicitRestartRestartingChild :: ProcessId -> Process ()
explicitRestartRestartingChild sup = do
  let spec = permChild $(mkStaticClosure 'noOp)
  ChildAdded _ <- startChild sup spec
  -- TODO: we've seen a few explosions here (presumably of the supervisor?)
  -- expecially when running with +RTS -N1 - it's possible that there's a bug
  -- tucked away that we haven't cracked just yet
  restarted <- (restartChild sup (childKey spec)) `catchExit` (\_ (r :: ExitReason) -> (liftIO $ putStrLn (show r)) >> die r)
  -- this is highly timing dependent, so we have to allow for both
  -- possible outcomes - on a dual core machine, the first clause
  -- will match approx. 1 / 200 times when running with +RTS -N
  case restarted of
    ChildRestartFailed (StartFailureAlreadyRunning (ChildRestarting _)) -> return ()
    ChildRestartFailed (StartFailureAlreadyRunning (ChildRunning _)) -> return ()
    other -> liftIO $ assertFailure $ "unexpected result: " ++ (show other)

explicitRestartStoppedChild :: ProcessId -> Process ()
explicitRestartStoppedChild sup = do
  let spec = transientWorker $(mkStaticClosure 'blockIndefinitely)
  let key = childKey spec
  ChildAdded ref <- startChild sup spec
  void $ terminateChild sup key
  restarted <- restartChild sup key
  sleepFor 500 Millis
  Just (ref', _) <- lookupChild sup key
  expectThat ref $ isNot $ equalTo ref'
  case restarted of
    ChildRestartOk (ChildRunning _) -> return ()
    _ -> liftIO $ assertFailure $ "unexpected termination: " ++ (show restarted)

terminateChildImmediately :: ProcessId -> Process ()
terminateChildImmediately sup = do
  let spec = tempWorker $(mkStaticClosure 'blockIndefinitely)
  ChildAdded ref <- startChild sup spec
--  Just pid <- resolve ref
  mRef <- monitor ref
  void $ terminateChild sup (childKey spec)
  reason <- waitForDown mRef
  expectThat reason $ equalTo $ DiedException (expectedExitReason sup)

terminatingChildExceedsDelay :: ProcessId -> Process ()
terminatingChildExceedsDelay sup = do
  let spec = (tempWorker $(mkStaticClosure 'sleepy))
             { childStop = TerminateTimeout (Delay $ within 1 Seconds) }
  ChildAdded ref <- startChild sup spec
-- Just pid <- resolve ref
  mRef <- monitor ref
  void $ terminateChild sup (childKey spec)
  reason <- waitForDown mRef
  expectThat reason $ equalTo $ DiedException (expectedExitReason sup)

terminatingChildObeysDelay :: ProcessId -> Process ()
terminatingChildObeysDelay sup = do
  let spec = (tempWorker $(mkStaticClosure 'obedient))
             { childStop = TerminateTimeout (Delay $ within 1 Seconds) }
  ChildAdded child <- startChild sup spec
  Just pid <- resolve child
  testProcessGo pid
  void $ monitor pid
  void $ terminateChild sup (childKey spec)
  child `shouldExitWith` DiedNormal

restartAfterThreeAttempts ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
restartAfterThreeAttempts withSupervisor = do
  let spec = permChild $(mkStaticClosure 'blockIndefinitely)
  let strategy = RestartOne $ limit (maxRestarts 500) (seconds 2)
  withSupervisor strategy [spec] $ \sup -> do
    mapM_ (\_ -> do
      [(childRef, _)] <- listChildren sup
      Just pid <- resolve childRef
      ref <- monitor pid
      testProcessStop pid
      void $ waitForDown ref) [1..3 :: Int]
    [(_, _)] <- listChildren sup
    return ()

{-
delayedRestartAfterThreeAttempts ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
delayedRestartAfterThreeAttempts withSupervisor = do
  let restartPolicy = DelayedRestart Permanent (within 1 Seconds)
  let spec = (permChild $(mkStaticClosure 'blockIndefinitely))
             { childRestart = restartPolicy }
  let strategy = RestartOne $ limit (maxRestarts 2) (seconds 1)
  withSupervisor strategy [spec] $ \sup -> do
    mapM_ (\_ -> do
      [(childRef, _)] <- listChildren sup
      Just pid <- resolve childRef
      ref <- monitor pid
      testProcessStop pid
      void $ waitForDown ref) [1..3 :: Int]
    Just (ref, _) <- lookupChild sup $ childKey spec
    case ref of
      ChildRestarting _ -> return ()
      _ -> liftIO $ assertFailure $ "Unexpected ChildRef: " ++ (show ref)
    sleep $ seconds 2
    [(ref', _)] <- listChildren sup
    liftIO $ putStrLn $ "it is: " ++ (show ref')
    Just pid <- resolve ref'
    mRef <- monitor pid
    testProcessStop pid
    void $ waitForDown mRef
-}

permanentChildExceedsRestartsIntensity ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
permanentChildExceedsRestartsIntensity withSupervisor = do
  let spec = permChild $(mkStaticClosure 'noOp)  -- child that exits immediately
  let strategy = RestartOne $ limit (maxRestarts 50) (seconds 2)
  withSupervisor strategy [spec] $ \sup -> do
    ref <- monitor sup
    -- if the supervisor dies whilst the call is in-flight,
    -- *this* process will exit, therefore we handle that exit reason
    void $ ((startChild sup spec >> return ())
             `catchExit` (\_ (_ :: ExitReason) -> return ()))
    reason <- waitForDown ref
    expectThat reason $ equalTo $
                      DiedException $ "exit-from=" ++ (show sup) ++
                                      ",reason=ReachedMaxRestartIntensity"

terminateChildIgnoresSiblings ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
terminateChildIgnoresSiblings withSupervisor = do
  let templ = permChild $(mkStaticClosure 'blockIndefinitely)
  let specs = [templ { childKey = (show i) } | i <- [1..3 :: Int]]
  withSupervisor restartAll specs $ \sup -> do
    let toStop = childKey $ head specs
    Just (ref, _) <- lookupChild sup toStop
    mRef <- monitor ref
    terminateChild sup toStop
    waitForDown mRef
    children <- listChildren sup
    forM_ (tail $ map fst children) $ \cRef -> do
      maybe (error "invalid ref") ensureProcessIsAlive =<< resolve cRef

restartAllWithLeftToRightSeqRestarts ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
restartAllWithLeftToRightSeqRestarts withSupervisor = do
  let templ = permChild $(mkStaticClosure 'blockIndefinitely)
  let specs = [templ { childKey = (show i) } | i <- [1..100 :: Int]]
  withSupervisor restartAll specs $ \sup -> do
    let toStop = childKey $ head specs
    Just (ref, _) <- lookupChild sup toStop
    children <- listChildren sup
    Just pid <- resolve ref
    kill pid "goodbye"
    forM_ (map fst children) $ \cRef -> do
      mRef <- monitor cRef
      waitForDown mRef
    forM_ (map snd children) $ \cSpec -> do
      Just (ref', _) <- lookupChild sup (childKey cSpec)
      maybe (error "invalid ref") ensureProcessIsAlive =<< resolve ref'

restartLeftWithLeftToRightSeqRestarts ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
restartLeftWithLeftToRightSeqRestarts withSupervisor = do
  let templ = permChild $(mkStaticClosure 'blockIndefinitely)
  let specs = [templ { childKey = (show i) } | i <- [1..500 :: Int]]
  withSupervisor restartLeft specs $ \sup -> do
    let (toRestart, _notToRestart) = splitAt 100 specs
    let toStop = childKey $ last toRestart
    Just (ref, _) <- lookupChild sup toStop
    Just pid <- resolve ref
    children <- listChildren sup
    let (children', survivors) = splitAt 100 children
    kill pid "goodbye"
    forM_ (map fst children') $ \cRef -> do
      mRef <- monitor cRef
      waitForDown mRef
    forM_ (map snd children') $ \cSpec -> do
      Just (ref', _) <- lookupChild sup (childKey cSpec)
      maybe (error "invalid ref") ensureProcessIsAlive =<< resolve ref'
    resolved <- forM (map fst survivors) resolve
    let possibleBadRestarts = catMaybes resolved
    r <- receiveTimeout (after 1 Seconds) [
        match (\(ProcessMonitorNotification _ pid' _) -> do
          case (elem pid' possibleBadRestarts) of
            True  -> liftIO $ assertFailure $ "unexpected exit from " ++ show pid'
            False -> return ())
      ]
    expectThat r isNothing

restartRightWithLeftToRightSeqRestarts ::
     (RestartStrategy -> [ChildSpec] -> (ProcessId -> Process ()) -> Assertion)
  -> Assertion
restartRightWithLeftToRightSeqRestarts withSupervisor = do
  let templ = permChild $(mkStaticClosure 'blockIndefinitely)
  let specs = [templ { childKey = (show i) } | i <- [1..50 :: Int]]
  withSupervisor restartRight specs $ \sup -> do
    let (_notToRestart, toRestart) = splitAt 40 specs
    let toStop = childKey $ head toRestart
    Just (ref, _) <- lookupChild sup toStop
    Just pid <- resolve ref
    children <- listChildren sup
    let (survivors, children') = splitAt 40 children
    kill pid "goodbye"
    forM_ (map fst children') $ \cRef -> do
      mRef <- monitor cRef
      waitForDown mRef
    forM_ (map snd children') $ \cSpec -> do
      Just (ref', _) <- lookupChild sup (childKey cSpec)
      maybe (error "invalid ref") ensureProcessIsAlive =<< resolve ref'
    resolved <- forM (map fst survivors) resolve
    let possibleBadRestarts = catMaybes resolved
    r <- receiveTimeout (after 1 Seconds) [
        match (\(ProcessMonitorNotification _ pid' _) -> do
          case (elem pid' possibleBadRestarts) of
            True  -> liftIO $ assertFailure $ "unexpected exit from " ++ show pid'
            False -> return ())
      ]
    expectThat r isNothing

restartAllWithLeftToRightRestarts :: ProcessId -> Process ()
restartAllWithLeftToRightRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..100 :: Int]]
  -- add the specs one by one
  forM_ specs $ \s -> void $ startChild sup s
  -- assert that we saw the startup sequence working...
  children <- listChildren sup
  drainAllChildren children
  let toStop = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStop
  Just pid <- resolve ref
  kill pid "goodbye"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst children) $ \cRef -> do
    Just mRef <- monitor cRef
    receiveWait [
        matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == mRef)
                (\_ -> return ())
        -- we should NOT see *any* process signalling that it has started
        -- whilst waiting for all the children to be terminated
      , match (\(pid' :: ProcessId) -> do
            liftIO $ assertFailure $ "unexpected signal from " ++ (show pid'))
      ]
  -- Now assert that all the children were restarted in the same order.
  -- THIS is the bit that is technically unsafe, though it's also unlikely
  -- to change, since the architecture of the node controller is pivotal to CH
  children' <- listChildren sup
  drainAllChildren children'
  let [c1, c2] = [map fst cs | cs <- [children, children']]
  forM_ (zip c1 c2) $ \(p1, p2) -> expectThat p1 $ isNot $ equalTo p2
  where
    drainAllChildren children = do
      -- Receive all pids then verify they arrived in the correct order.
      -- Any out-of-order messages (such as ProcessMonitorNotification) will
      -- violate the invariant asserted below, and fail the test case
      pids <- forM children $ \_ -> expect :: Process ProcessId
      forM_ pids ensureProcessIsAlive

restartAllWithRightToLeftSeqRestarts :: ProcessId -> Process ()
restartAllWithRightToLeftSeqRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..100 :: Int]]
  -- add the specs one by one
  forM_ specs $ \s -> do
    ChildAdded ref <- startChild sup s
    maybe (error "invalid ref") ensureProcessIsAlive =<< resolve ref
  -- assert that we saw the startup sequence working...
  let toStop = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStop
  Just pid <- resolve ref
  children <- listChildren sup
  drainChildren children pid
  kill pid "fooboo"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst children) $ \cRef -> do
    Just mRef <- monitor cRef
    receiveWait [
        matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == mRef)
                (\_ -> return ())
      ]
  -- ensure that both ends of the pids we've seen are in the right order...
  -- in this case, we expect the last child to be the first notification,
  -- since they were started in right to left order
  children' <- listChildren sup
  let (ref', _) = last children'
  Just pid' <- resolve ref'
  drainChildren children' pid'

expectLeftToRightRestarts :: ProcessId -> Process ()
expectLeftToRightRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..100 :: Int]]
  -- add the specs one by one
  forM_ specs $ \s -> do
    ChildAdded c <- startChild sup s
    Just p <- resolve c
    p' <- expect
    p' `shouldBe` equalTo p
  -- assert that we saw the startup sequence working...
  let toStop = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStop
  Just pid <- resolve ref
  children <- listChildren sup
  -- wait for all the exit signals and ensure they arrive in RightToLeft order
  refs <- forM children $ \(ch, _) -> monitor ch >>= \r -> return (ch, r)
  kill pid "fooboo"
  initRes <- receiveTimeout
               (asTimeout $ seconds 1)
               [ matchIf (\(ProcessMonitorNotification r _ _) -> (Just r) == (snd $ head refs))
                         (\sig@(ProcessMonitorNotification _ _ _) -> return sig) ]
  expectThat initRes $ isJust
  forM_ (reverse (filter ((/= ref) .fst ) refs)) $ \(_, Just mRef) -> do
    (ProcessMonitorNotification ref' _ _) <- expect
    if ref' == mRef then (return ()) else (die "unexpected monitor signal")
  -- in this case, we expect the first child to be the first notification,
  -- since they were started in left to right order
  children' <- listChildren sup
  let (ref', _) = head children'
  Just pid' <- resolve ref'
  drainChildren children' pid'

expectRightToLeftRestarts :: ProcessId -> Process ()
expectRightToLeftRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..10 :: Int]]
  -- add the specs one by one
  forM_ specs $ \s -> do
    ChildAdded ref <- startChild sup s
    maybe (error "invalid ref") ensureProcessIsAlive =<< resolve ref
  -- assert that we saw the startup sequence working...
  let toStop = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStop
  Just pid <- resolve ref
  children <- listChildren sup
  drainChildren children pid
  kill pid "fooboo"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst children) $ \cRef -> do
    Just mRef <- monitor cRef
    receiveWait [
        matchIf (\(ProcessMonitorNotification ref' _ _) -> ref' == mRef)
                (\_ -> return ())
        -- we should NOT see *any* process signalling that it has started
        -- whilst waiting for all the children to be terminated
      , match (\(pid' :: ProcessId) -> do
            liftIO $ assertFailure $ "unexpected signal from " ++ (show pid'))
      ]
  -- ensure that both ends of the pids we've seen are in the right order...
  -- in this case, we expect the last child to be the first notification,
  -- since they were started in right to left order
  children' <- listChildren sup
  let (ref', _) = last children'
  Just pid' <- resolve ref'
  drainChildren children' pid'

restartLeftWhenLeftmostChildDies :: ProcessId -> Process ()
restartLeftWhenLeftmostChildDies sup = do
  let spec = permChild $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref) <- startChild sup spec
  (ChildAdded ref2) <- startChild sup $ spec { childKey = "child2" }
  Just pid <- resolve ref
  Just pid2 <- resolve ref2
  testProcessStop pid  -- a normal stop should *still* trigger a restart
  verifyChildWasRestarted (childKey spec) pid sup
  Just (ref3, _) <- lookupChild sup "child2"
  Just pid2' <- resolve ref3
  pid2 `shouldBe` equalTo pid2'

restartRightWhenRightmostChildDies :: ProcessId -> Process ()
restartRightWhenRightmostChildDies sup = do
  let spec = permChild $(mkStaticClosure 'blockIndefinitely)
  (ChildAdded ref2) <- startChild sup $ spec { childKey = "child2" }
  (ChildAdded ref) <- startChild sup $ spec { childKey = "child1" }
  [ch1, ch2] <- listChildren sup
  (fst ch1) `shouldBe` equalTo ref2
  (fst ch2) `shouldBe` equalTo ref
  Just pid <- resolve ref
  Just pid2 <- resolve ref2
  -- ref (and therefore pid) is 'rightmost' now
  testProcessStop pid  -- a normal stop should *still* trigger a restart
  verifyChildWasRestarted "child1" pid sup
  Just (ref3, _) <- lookupChild sup "child2"
  Just pid2' <- resolve ref3
  pid2 `shouldBe` equalTo pid2'

restartLeftWithLeftToRightRestarts :: ProcessId -> Process ()
restartLeftWithLeftToRightRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..20 :: Int]]
  forM_ specs $ \s -> void $ startChild sup s
  -- assert that we saw the startup sequence working...
  let toStart = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStart
  Just pid <- resolve ref
  children <- listChildren sup
  drainChildren children pid
  let (toRestart, _) = splitAt 7 specs
  let toStop = childKey $ last toRestart
  Just (ref', _) <- lookupChild sup toStop
  Just stopPid <- resolve ref'
  kill stopPid "goodbye"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst (fst $ splitAt 7 children)) $ \cRef -> do
    mRef <- monitor cRef
    waitForDown mRef
  children' <- listChildren sup
  let (restarted, notRestarted) = splitAt 7 children'
  -- another (technically) unsafe check
  let firstRestart = childKey $ snd $ head restarted
  Just (rRef, _) <- lookupChild sup firstRestart
  Just fPid <- resolve rRef
  drainChildren restarted fPid
  let [c1, c2] = [map fst cs | cs <- [(snd $ splitAt 7 children), notRestarted]]
  forM_ (zip c1 c2) $ \(p1, p2) -> p1 `shouldBe` equalTo p2

restartRightWithLeftToRightRestarts :: ProcessId -> Process ()
restartRightWithLeftToRightRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..20 :: Int]]
  forM_ specs $ \s -> void $ startChild sup s
  -- assert that we saw the startup sequence working...
  let toStart = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStart
  Just pid <- resolve ref
  children <- listChildren sup
  drainChildren children pid
  let (_, toRestart) = splitAt 3 specs
  let toStop = childKey $ head toRestart
  Just (ref', _) <- lookupChild sup toStop
  Just stopPid <- resolve ref'
  kill stopPid "goodbye"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst (snd $ splitAt 3 children)) $ \cRef -> do
    mRef <- monitor cRef
    waitForDown mRef
  children' <- listChildren sup
  let (notRestarted, restarted) = splitAt 3 children'
  -- another (technically) unsafe check
  let firstRestart = childKey $ snd $ head restarted
  Just (rRef, _) <- lookupChild sup firstRestart
  Just fPid <- resolve rRef
  drainChildren restarted fPid
  let [c1, c2] = [map fst cs | cs <- [(fst $ splitAt 3 children), notRestarted]]
  forM_ (zip c1 c2) $ \(p1, p2) -> p1 `shouldBe` equalTo p2

restartRightWithRightToLeftRestarts :: ProcessId -> Process ()
restartRightWithRightToLeftRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..20 :: Int]]
  forM_ specs $ \s -> void $ startChild sup s
  -- assert that we saw the startup sequence working...
  let toStart = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStart
  Just pid <- resolve ref
  children <- listChildren sup
  drainChildren children pid
  let (_, toRestart) = splitAt 3 specs
  let toStop = childKey $ head toRestart
  Just (ref', _) <- lookupChild sup toStop
  Just stopPid <- resolve ref'
  kill stopPid "goodbye"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst (snd $ splitAt 3 children)) $ \cRef -> do
    mRef <- monitor cRef
    waitForDown mRef
  children' <- listChildren sup
  let (notRestarted, restarted) = splitAt 3 children'
  -- another (technically) unsafe check
  let firstRestart = childKey $ snd $ last restarted
  Just (rRef, _) <- lookupChild sup firstRestart
  Just fPid <- resolve rRef
  drainChildren restarted fPid
  let [c1, c2] = [map fst cs | cs <- [(fst $ splitAt 3 children), notRestarted]]
  forM_ (zip c1 c2) $ \(p1, p2) -> p1 `shouldBe` equalTo p2

restartLeftWithRightToLeftRestarts :: ProcessId -> Process ()
restartLeftWithRightToLeftRestarts sup = do
  self <- getSelfPid
  let templ = permChild ($(mkClosure 'notifyMe) self)
  let specs = [templ { childKey = (show i) } | i <- [1..20 :: Int]]
  forM_ specs $ \s -> void $ startChild sup s
  -- assert that we saw the startup sequence working...
  let toStart = childKey $ head specs
  Just (ref, _) <- lookupChild sup toStart
  Just pid <- resolve ref
  children <- listChildren sup
  drainChildren children pid
  let (toRestart, _) = splitAt 7 specs
  let (restarts, toSurvive) = splitAt 7 children
  let toStop = childKey $ last toRestart
  Just (ref', _) <- lookupChild sup toStop
  Just stopPid <- resolve ref'
  kill stopPid "goodbye"
  -- wait for all the exit signals, so we know the children are restarting
  forM_ (map fst restarts) $ \cRef -> do
    mRef <- monitor cRef
    waitForDown mRef
  children' <- listChildren sup
  let (restarted, notRestarted) = splitAt 7 children'
  -- another (technically) unsafe check
  let firstRestart = childKey $ snd $ last restarted
  Just (rRef, _) <- lookupChild sup firstRestart
  Just fPid <- resolve rRef
  drainChildren (reverse restarted) fPid
  let [c1, c2] = [map fst cs | cs <- [toSurvive, notRestarted]]
  forM_ (zip c1 c2) $ \(p1, p2) -> p1 `shouldBe` equalTo p2

-- remote table definition and main

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

tests :: NT.Transport -> IO [Test]
tests transport = do
  putStrLn "NOTICE: Branch Tests (Relying on Non-Guaranteed Message Order) Can Fail Intermittently"
  localNode <- newLocalNode transport myRemoteTable
  singleTestLock <- newMVar ()
  let withSupervisor = runInTestContext localNode singleTestLock
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
          , testCase "Start Bad Clousre"
                (withSupervisor restartOne [] startBadClosure)
          , testCase "Configured Bad Closure"
                (configuredTemporaryChildExitsWithIgnore withSupervisor)
          , testCase "Started Non-Temporary Child Exits With Ignore"
                (withSupervisor restartOne [] startNonTemporaryChildExitsWithIgnore)
          , testCase "Configured Non-Temporary Child Exits With Ignore"
                (configuredNonTemporaryChildExitsWithIgnore withSupervisor)
          ]
        , testGroup "Stopping And Deleting Children"
          [
            testCase "Delete Existing Child Fails"
                (withSupervisor restartOne [] deleteExistingChild)
          , testCase "Delete Stopped Temporary Child (Doesn't Exist)"
                (withSupervisor restartOne [] deleteStoppedTempChild)
          , testCase "Delete Stopped Child Succeeds"
                (withSupervisor restartOne [] deleteStoppedChild)
          ]
        , testGroup "Stopping and Restarting Children"
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
          , testCase "Explicit Restart Of Running Child Fails"
                (withSupervisor restartOne [] explicitRestartRunningChild)
          , testCase "Explicit Restart Of Unknown Child Fails"
                (withSupervisor restartOne [] explicitRestartUnknownChild)
          , testCase "Explicit Restart Whilst Child Restarting Fails"
                (withSupervisor
                 (RestartOne (limit (maxRestarts 500000000) (milliSeconds 1))) []
                  explicitRestartRestartingChild)
          , testCase "Explicit Restart Stopped Child"
                (withSupervisor restartOne [] explicitRestartStoppedChild)
          , testCase "Immediate Child Termination (Brutal Kill)"
                (withSupervisor restartOne [] terminateChildImmediately)
          , testCase "Child Termination Exceeds Timeout/Delay (Becomes Brutal Kill)"
                (withSupervisor restartOne [] terminatingChildExceedsDelay)
          , testCase "Child Termination Within Timeout/Delay"
                (withSupervisor restartOne [] terminatingChildObeysDelay)
          ]
          -- TODO: test for init failures (expecting $ ChildInitFailed r)
        , testGroup "Branch Restarts"
          [
            testGroup "Restart All"
            [
              testCase "Terminate Child Ignores Siblings"
                  (terminateChildIgnoresSiblings withSupervisor)
            , testCase "Restart All, Left To Right (Sequential) Restarts"
                  (restartAllWithLeftToRightSeqRestarts withSupervisor)
            , testCase "Restart All, Right To Left (Sequential) Restarts"
                  (withSupervisor
                   (RestartAll defaultLimits (RestartEach RightToLeft)) []
                    restartAllWithRightToLeftSeqRestarts)
            , testCase "Restart All, Left To Right Stop, Left To Right Start"
                  (withSupervisor
                   (RestartAll defaultLimits (RestartInOrder LeftToRight)) []
                    restartAllWithLeftToRightRestarts)
            , testCase "Restart All, Right To Left Stop, Right To Left Start"
                  (withSupervisor
                   (RestartAll defaultLimits (RestartInOrder RightToLeft)) []
                    expectRightToLeftRestarts)
            , testCase "Restart All, Left To Right Stop, Reverse Start"
                  (withSupervisor
                   (RestartAll defaultLimits (RestartRevOrder LeftToRight)) []
                    expectRightToLeftRestarts)
            , testCase "Restart All, Right To Left Stop, Reverse Start"
                  (withSupervisor
                   (RestartAll defaultLimits (RestartRevOrder RightToLeft)) []
                    expectLeftToRightRestarts)
            ],
            testGroup "Restart Left"
            [
              testCase "Restart Left, Left To Right (Sequential) Restarts"
                  (restartLeftWithLeftToRightSeqRestarts withSupervisor)
            , testCase "Restart Left, Leftmost Child Dies"
                  (withSupervisor restartLeft [] restartLeftWhenLeftmostChildDies)
            , testCase "Restart Left, Left To Right Stop, Left To Right Start"
                  (withSupervisor
                   (RestartLeft defaultLimits (RestartInOrder LeftToRight)) []
                    restartLeftWithLeftToRightRestarts)
            , testCase "Restart Left, Right To Left Stop, Right To Left Start"
                  (withSupervisor
                   (RestartLeft defaultLimits (RestartInOrder RightToLeft)) []
                    restartLeftWithRightToLeftRestarts)
            , testCase "Restart Left, Left To Right Stop, Reverse Start"
                  (withSupervisor
                   (RestartLeft defaultLimits (RestartRevOrder LeftToRight)) []
                    restartLeftWithRightToLeftRestarts)
            , testCase "Restart Left, Right To Left Stop, Reverse Start"
                  (withSupervisor
                   (RestartLeft defaultLimits (RestartRevOrder RightToLeft)) []
                    restartLeftWithLeftToRightRestarts)
            ],
            testGroup "Restart Right"
            [
              testCase "Restart Right, Left To Right (Sequential) Restarts"
                  (restartRightWithLeftToRightSeqRestarts withSupervisor)
            , testCase "Restart Right, Rightmost Child Dies"
                  (withSupervisor restartRight [] restartRightWhenRightmostChildDies)
            , testCase "Restart Right, Left To Right Stop, Left To Right Start"
                  (withSupervisor
                   (RestartRight defaultLimits (RestartInOrder LeftToRight)) []
                    restartRightWithLeftToRightRestarts)
            , testCase "Restart Right, Right To Left Stop, Right To Left Start"
                  (withSupervisor
                   (RestartRight defaultLimits (RestartInOrder RightToLeft)) []
                    restartRightWithRightToLeftRestarts)
            , testCase "Restart Right, Left To Right Stop, Reverse Start"
                  (withSupervisor
                   (RestartRight defaultLimits (RestartRevOrder LeftToRight)) []
                    restartRightWithRightToLeftRestarts)
            , testCase "Restart Right, Right To Left Stop, Reverse Start"
                  (withSupervisor
                   (RestartRight defaultLimits (RestartRevOrder RightToLeft)) []
                    restartRightWithLeftToRightRestarts)
            ]
            ]
        , testGroup "Restart Intensity"
          [
            testCase "Three Attempts Before Successful Restart"
                (restartAfterThreeAttempts withSupervisor)
          , testCase "Permanent Child Exceeds Restart Limits"
                (permanentChildExceedsRestartsIntensity withSupervisor)
--          , testCase "Permanent Child Delayed Restart"
--                (delayedRestartAfterThreeAttempts withSupervisor)
          ]
      ]
    ]

main :: IO ()
main = testMain $ tests

