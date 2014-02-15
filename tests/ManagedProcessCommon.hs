{-# LANGUAGE ScopedTypeVariables #-}

module ManagedProcessCommon where

import Control.Concurrent.MVar (MVar)
import Control.Distributed.Process hiding (call, send)
import Control.Distributed.Process.Platform hiding (monitor)
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
import qualified Control.Distributed.Process.Platform.ManagedProcess.UnsafeClient as Unsafe
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
import Control.Distributed.Process.Serializable()

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import TestUtils

type Launcher a = a -> Process (ProcessId, MVar ExitReason)

explodingTestProcess :: ProcessId -> ProcessDefinition ()
explodingTestProcess pid =
  statelessProcess {
    apiHandlers = [
       handleCall_ (\(s :: String) ->
                     (die s) :: Process String)
     , handleCast  (\_ (i :: Int) ->
                     getSelfPid >>= \p -> die (p, i))
     ]
  , exitHandlers = [
       handleExit  (\s _ (m :: String) -> send pid (m :: String) >>
                                          continue s)
     , handleExit  (\s _ m@((_ :: ProcessId),
                            (_ :: Int)) -> send pid m >> continue s)
     ]
  }

standardTestServer :: UnhandledMessagePolicy -> ProcessDefinition ()
standardTestServer policy =
  statelessProcess {
        apiHandlers = [
              -- note: state is passed here, as a 'stateless' process is
              -- in fact process definition whose state is ()

              handleCastIf  (input (\msg -> msg == "stop"))
                            (\_ _ -> stop ExitNormal)

            , handleCall    (\s' (m :: String) -> reply m s')
            , handleCall_   (\(n :: Int) -> return (n * 2))    -- "stateless"

            , handleCast    (\s' ("ping", pid :: ProcessId) ->
                                 send pid "pong" >> continue s')
            , handleCastIf_ (input (\(c :: String, _ :: Delay) -> c == "timeout"))
                            (\("timeout", d) -> timeoutAfter_ d)

            , handleCast_   (\("hibernate", d :: TimeInterval) -> hibernate_ d)
          ]
      , unhandledMessagePolicy = policy
      , timeoutHandler         = \_ _ -> stop $ ExitOther "timeout"
    }

wrap :: (Process (ProcessId, MVar ExitReason)) -> Launcher a
wrap it = \_ -> do it

-- common test cases

testBasicCall :: Launcher () -> TestResult (Maybe String) -> Process ()
testBasicCall launch result = do
  (pid, _) <- launch ()
  callTimeout pid "foo" (within 5 Seconds) >>= stash result

testUnsafeBasicCall :: Launcher () -> TestResult (Maybe String) -> Process ()
testUnsafeBasicCall launch result = do
  (pid, _) <- launch ()
  Unsafe.callTimeout pid "foo" (within 5 Seconds) >>= stash result

testBasicCall_ :: Launcher () -> TestResult (Maybe Int) -> Process ()
testBasicCall_ launch result = do
  (pid, _) <- launch ()
  callTimeout pid (2 :: Int) (within 5 Seconds) >>= stash result

testUnsafeBasicCall_ :: Launcher () -> TestResult (Maybe Int) -> Process ()
testUnsafeBasicCall_ launch result = do
  (pid, _) <- launch ()
  Unsafe.callTimeout pid (2 :: Int) (within 5 Seconds) >>= stash result

testBasicCast :: Launcher () -> TestResult (Maybe String) -> Process ()
testBasicCast launch result = do
  self <- getSelfPid
  (pid, _) <- launch ()
  cast pid ("ping", self)
  expectTimeout (after 3 Seconds) >>= stash result

testUnsafeBasicCast :: Launcher () -> TestResult (Maybe String) -> Process ()
testUnsafeBasicCast launch result = do
  self <- getSelfPid
  (pid, _) <- launch ()
  Unsafe.cast pid ("ping", self)
  expectTimeout (after 3 Seconds) >>= stash result

testControlledTimeout :: Launcher () -> TestResult (Maybe ExitReason) -> Process ()
testControlledTimeout launch result = do
  (pid, exitReason) <- launch ()
  cast pid ("timeout", Delay $ within 1 Seconds)
  waitForExit exitReason >>= stash result

testUnsafeControlledTimeout :: Launcher () -> TestResult (Maybe ExitReason) -> Process ()
testUnsafeControlledTimeout launch result = do
  (pid, exitReason) <- launch ()
  Unsafe.cast pid ("timeout", Delay $ within 1 Seconds)
  waitForExit exitReason >>= stash result

testTerminatePolicy :: Launcher () -> TestResult (Maybe ExitReason) -> Process ()
testTerminatePolicy launch result = do
  (pid, exitReason) <- launch ()
  send pid ("UNSOLICITED_MAIL", 500 :: Int)
  waitForExit exitReason >>= stash result

testUnsafeTerminatePolicy :: Launcher () -> TestResult (Maybe ExitReason) -> Process ()
testUnsafeTerminatePolicy launch result = do
  (pid, exitReason) <- launch ()
  send pid ("UNSOLICITED_MAIL", 500 :: Int)
  waitForExit exitReason >>= stash result

testDropPolicy :: Launcher () -> TestResult (Maybe ExitReason) -> Process ()
testDropPolicy launch result = do
  (pid, exitReason) <- launch ()

  send pid ("UNSOLICITED_MAIL", 500 :: Int)

  sleep $ milliSeconds 250
  mref <- monitor pid

  cast pid "stop"

  r <- receiveTimeout (after 10 Seconds) [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\(ProcessMonitorNotification _ _ r) ->
                case r of
                  DiedUnknownId -> stash result Nothing
                  _ -> waitForExit exitReason >>= stash result)
    ]
  case r of
    Nothing -> stash result Nothing
    _       -> return ()

testUnsafeDropPolicy :: Launcher () -> TestResult (Maybe ExitReason) -> Process ()
testUnsafeDropPolicy launch result = do
  (pid, exitReason) <- launch ()

  send pid ("UNSOLICITED_MAIL", 500 :: Int)

  sleep $ milliSeconds 250
  mref <- monitor pid

  Unsafe.cast pid "stop"

  r <- receiveTimeout (after 10 Seconds) [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\(ProcessMonitorNotification _ _ r) ->
                case r of
                  DiedUnknownId -> stash result Nothing
                  _ -> waitForExit exitReason >>= stash result)
    ]
  case r of
    Nothing -> stash result Nothing
    _       -> return ()

testDeadLetterPolicy :: Launcher ProcessId
                     -> TestResult (Maybe (String, Int))
                     -> Process ()
testDeadLetterPolicy launch result = do
  self <- getSelfPid
  (pid, _) <- launch self

  send pid ("UNSOLICITED_MAIL", 500 :: Int)
  cast pid "stop"

  receiveTimeout
    (after 5 Seconds)
    [ match (\m@(_ :: String, _ :: Int) -> return m) ] >>= stash result

testUnsafeDeadLetterPolicy :: Launcher ProcessId
                     -> TestResult (Maybe (String, Int))
                     -> Process ()
testUnsafeDeadLetterPolicy launch result = do
  self <- getSelfPid
  (pid, _) <- launch self

  send pid ("UNSOLICITED_MAIL", 500 :: Int)
  Unsafe.cast pid "stop"

  receiveTimeout
    (after 5 Seconds)
    [ match (\m@(_ :: String, _ :: Int) -> return m) ] >>= stash result

testHibernation :: Launcher () -> TestResult Bool -> Process ()
testHibernation launch result = do
  (pid, _) <- launch ()
  mref <- monitor pid

  cast pid ("hibernate", (within 3 Seconds))
  cast pid "stop"

  -- the process mustn't stop whilst it's supposed to be hibernating
  r <- receiveTimeout (after 2 Seconds) [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\_ -> return ())
    ]
  case r of
    Nothing -> kill pid "done" >> stash result True
    Just _  -> stash result False

testUnsafeHibernation :: Launcher () -> TestResult Bool -> Process ()
testUnsafeHibernation launch result = do
  (pid, _) <- launch ()
  mref <- monitor pid

  Unsafe.cast pid ("hibernate", (within 3 Seconds))
  Unsafe.cast pid "stop"

  -- the process mustn't stop whilst it's supposed to be hibernating
  r <- receiveTimeout (after 2 Seconds) [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\_ -> return ())
    ]
  case r of
    Nothing -> kill pid "done" >> stash result True
    Just _  -> stash result False

testKillMidCall :: Launcher () -> TestResult Bool -> Process ()
testKillMidCall launch result = do
  (pid, _) <- launch ()
  cast pid ("hibernate", (within 3 Seconds))
  callAsync pid "hello-world" >>= cancelWait >>= unpack result pid
  where unpack :: TestResult Bool -> ProcessId -> AsyncResult () -> Process ()
        unpack res sid AsyncCancelled = kill sid "stop" >> stash res True
        unpack res sid _              = kill sid "stop" >> stash res False

testUnsafeKillMidCall :: Launcher () -> TestResult Bool -> Process ()
testUnsafeKillMidCall launch result = do
  (pid, _) <- launch ()
  Unsafe.cast pid ("hibernate", (within 3 Seconds))
  Unsafe.callAsync pid "hello-world" >>= cancelWait >>= unpack result pid
  where unpack :: TestResult Bool -> ProcessId -> AsyncResult () -> Process ()
        unpack res sid AsyncCancelled = kill sid "stop" >> stash res True
        unpack res sid _              = kill sid "stop" >> stash res False

testSimpleErrorHandling :: Launcher ProcessId
                        -> TestResult (Maybe ExitReason)
                        -> Process ()
testSimpleErrorHandling launch result = do
  self <- getSelfPid
  (pid, exitReason) <- launch self

  -- this should be *altered* because of the exit handler
  Nothing <- callTimeout pid "foobar" (within 1 Seconds) :: Process (Maybe String)
  "foobar" <- expect

  shutdown pid
  waitForExit exitReason >>= stash result

testUnsafeSimpleErrorHandling :: Launcher ProcessId
                        -> TestResult (Maybe ExitReason)
                        -> Process ()
testUnsafeSimpleErrorHandling launch result = do
  self <- getSelfPid
  (pid, exitReason) <- launch self

  -- this should be *altered* because of the exit handler
  Nothing <- Unsafe.callTimeout pid "foobar" (within 1 Seconds) :: Process (Maybe String)
  "foobar" <- expect

  Unsafe.shutdown pid
  waitForExit exitReason >>= stash result

testAlternativeErrorHandling :: Launcher ProcessId
                             -> TestResult (Maybe ExitReason)
                             -> Process ()
testAlternativeErrorHandling launch result = do
  self <- getSelfPid
  (pid, exitReason) <- launch self

  -- this should be ignored/altered because of the second exit handler
  cast pid (42 :: Int)
  (Just True) <- receiveTimeout (after 2 Seconds) [
        matchIf (\((p :: ProcessId), (i :: Int)) -> p == pid && i == 42)
                (\_ -> return True)
      ]

  shutdown pid
  waitForExit exitReason >>= stash result

testUnsafeAlternativeErrorHandling :: Launcher ProcessId
                             -> TestResult (Maybe ExitReason)
                             -> Process ()
testUnsafeAlternativeErrorHandling launch result = do
  self <- getSelfPid
  (pid, exitReason) <- launch self

  -- this should be ignored/altered because of the second exit handler
  Unsafe.cast pid (42 :: Int)
  (Just True) <- receiveTimeout (after 2 Seconds) [
        matchIf (\((p :: ProcessId), (i :: Int)) -> p == pid && i == 42)
                (\_ -> return True)
      ]

  Unsafe.shutdown pid
  waitForExit exitReason >>= stash result

