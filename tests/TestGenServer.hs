{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImpredicativeTypes  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE TemplateHaskell     #-}

-- NB: this module contains tests for the GenProcess /and/ GenServer API.

module Main where

import Control.Concurrent.MVar
import Control.Exception (SomeException)
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform hiding (__remoteTable)
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
import Control.Distributed.Process.Serializable()

import Data.Binary
import Data.Typeable (Typeable)
import Data.DeriveTH
import MathsDemo
import Counter
import SimplePool

import Prelude hiding (catch)

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils

import qualified Network.Transport as NT
import Control.Monad (void)

-- utilities

data GetState = GetState
  deriving (Typeable, Show, Eq)
$(derive makeBinary ''GetState)

waitForExit :: MVar (Either (InitResult ()) TerminateReason)
            -> Process (Maybe TerminateReason)
waitForExit exitReason = do
    -- we *might* end up blocked here, so ensure the test doesn't jam up!
  self <- getSelfPid
  tref <- killAfter (within 10 Seconds) self "testcast timed out"
  tr <- liftIO $ takeMVar exitReason
  cancelTimer tref
  case tr of
    Right r -> return (Just r)
    Left  _ -> return Nothing

server :: Process ((ProcessId, MVar (Either (InitResult ()) TerminateReason)))
server = mkServer Terminate

mkServer :: UnhandledMessagePolicy
         -> Process (ProcessId, MVar (Either (InitResult ()) TerminateReason))
mkServer policy =
  let s = statelessProcess {
        apiHandlers = [
              -- note: state is passed here, as a 'stateless' process is
              -- in fact process definition whose state is ()

              handleCastIf  (input (\msg -> msg == "stop"))
                            (\_ _ -> stop TerminateNormal)

            , handleCall    (\s' (m :: String) -> reply m s')
            , handleCall_   (\(n :: Int) -> return (n * 2))    -- "stateless"

            , handleCast    (\s' ("ping", pid :: ProcessId) ->
                                 send pid "pong" >> continue s')
            , handleCastIf_ (input (\(c :: String, _ :: Delay) -> c == "timeout"))
                            (\("timeout", Delay d) -> timeoutAfter_ d)

            , handleCast_   (\("hibernate", d :: TimeInterval) -> hibernate_ d)
          ]
      , unhandledMessagePolicy = policy
      , timeoutHandler         = \_ _ -> stop $ TerminateOther "timeout"
    }
  in do
    exitReason <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
      catch (start () (statelessInit Infinity) s >>= stash exitReason)
            (\(e :: SomeException) -> stash exitReason $ Right (TerminateOther (show e)))
    return (pid, exitReason)

explodingServer :: ProcessId
                -> Process (ProcessId, MVar (Either (InitResult ()) TerminateReason))
explodingServer pid =
  let srv = statelessProcess {
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
  in do
    exitReason <- liftIO $ newEmptyMVar
    spid <- spawnLocal $ do
      catch (start () (statelessInit Infinity) srv >>= stash exitReason)
            (\(e :: SomeException) -> stash exitReason $ Right (TerminateOther (show e)))
    return (spid, exitReason)

startTestPool :: Int -> Process ProcessId
startTestPool s = spawnLocal $ do
  _ <- runPool s
  return ()

runPool :: Int -> Process (Either (InitResult (Pool String)) TerminateReason)
runPool s =
  let s' = poolServer :: ProcessDefinition (Pool String)
  in simplePool s s'

sampleTask :: (TimeInterval, String) -> Process String
sampleTask (t, s) = sleep t >> return s

namedTask :: (String, String) -> Process String
namedTask (name, result) = do
  self <- getSelfPid
  register name self
  () <- expect
  return result

$(remotable ['sampleTask, 'namedTask])

-- test cases

testBasicCall :: TestResult (Maybe String) -> Process ()
testBasicCall result = do
  (pid, _) <- server
  callTimeout pid "foo" (within 5 Seconds) >>= stash result

testBasicCall_ :: TestResult (Maybe Int) -> Process ()
testBasicCall_ result = do
  (pid, _) <- server
  callTimeout pid (2 :: Int) (within 5 Seconds) >>= stash result

testBasicCast :: TestResult (Maybe String) -> Process ()
testBasicCast result = do
  self <- getSelfPid
  (pid, _) <- server
  cast pid ("ping", self)
  expectTimeout (after 3 Seconds) >>= stash result

testControlledTimeout :: TestResult (Maybe TerminateReason) -> Process ()
testControlledTimeout result = do
  (pid, exitReason) <- server
  cast pid ("timeout", Delay $ within 1 Seconds)
  waitForExit exitReason >>= stash result

testTerminatePolicy :: TestResult (Maybe TerminateReason) -> Process ()
testTerminatePolicy result = do
  (pid, exitReason) <- server
  send pid ("UNSOLICITED_MAIL", 500 :: Int)
  waitForExit exitReason >>= stash result

testDropPolicy :: TestResult (Maybe TerminateReason) -> Process ()
testDropPolicy result = do
  (pid, exitReason) <- mkServer Drop

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

testDeadLetterPolicy :: TestResult (Maybe (String, Int)) -> Process ()
testDeadLetterPolicy result = do
  self <- getSelfPid
  (pid, _) <- mkServer (DeadLetter self)

  send pid ("UNSOLICITED_MAIL", 500 :: Int)
  cast pid "stop"

  receiveTimeout
    (after 5 Seconds)
    [ match (\m@(_ :: String, _ :: Int) -> return m) ] >>= stash result

testHibernation :: TestResult Bool -> Process ()
testHibernation result = do
  (pid, _) <- server
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

testKillMidCall :: TestResult Bool -> Process ()
testKillMidCall result = do
  (pid, _) <- server
  cast pid ("hibernate", (within 3 Seconds))
  callAsync pid "hello-world" >>= cancelWait >>= unpack result pid
  where unpack :: TestResult Bool -> ProcessId -> AsyncResult () -> Process ()
        unpack res sid AsyncCancelled = kill sid "stop" >> stash res True
        unpack res sid _              = kill sid "stop" >> stash res False

testSimpleErrorHandling :: TestResult (Maybe TerminateReason) -> Process ()
testSimpleErrorHandling result = do
  self <- getSelfPid
  (pid, exitReason) <- explodingServer self

  -- this should be *altered* because of the exit handler
  Nothing <- callTimeout pid "foobar" (within 1 Seconds) :: Process (Maybe String)
  "foobar" <- expect

  shutdown pid
  waitForExit exitReason >>= stash result

testAlternativeErrorHandling :: TestResult (Maybe TerminateReason) -> Process ()
testAlternativeErrorHandling result = do
  self <- getSelfPid
  (pid, exitReason) <- explodingServer self

  -- this should be ignored/altered because of the second exit handler
  cast pid (42 :: Int)
  (Just True) <- receiveTimeout (after 2 Seconds) [
        matchIf (\((p :: ProcessId), (i :: Int)) -> p == pid && i == 42)
                (\_ -> return True)
      ]

  shutdown pid
  waitForExit exitReason >>= stash result


-- SimplePool tests

testSimplePoolJobBlocksCaller :: TestResult (AsyncResult (Either String String))
                              -> Process ()
testSimplePoolJobBlocksCaller result = do
  pid <- startTestPool 1
  -- we do a non-blocking test first
  job <- return $ ($(mkClosure 'sampleTask) (seconds 2, "foobar"))
  callAsync pid job >>= wait >>= stash result

testJobQueueSizeLimiting ::
    TestResult (Maybe (AsyncResult (Either String String)),
                Maybe (AsyncResult (Either String String)))
                         -> Process ()
testJobQueueSizeLimiting result = do
  pid <- startTestPool 1
  job1 <- return $ ($(mkClosure 'namedTask) ("job1", "foo"))
  job2 <- return $ ($(mkClosure 'namedTask) ("job2", "bar"))
  h1 <- callAsync pid job1 :: Process (Async (Either String String))
  h2 <- callAsync pid job2 :: Process (Async (Either String String))

  -- despite the fact that we tell job2 to proceed first,
  -- the size limit (of 1) will ensure that only job1 can
  -- proceed successfully!
  nsend "job2" ()
  AsyncPending <- poll h2
  Nothing <- whereis "job2"

  -- we can get here *very* fast, we give the registration time to kick in
  sleep $ milliSeconds 250
  j1p <- whereis "job1"
  case j1p of
    Nothing -> die $ "timing is out - job1 isn't registered yet"
    Just p  -> send p ()

  -- once job1 completes, we *should* be able to proceed with job2
  -- but we allow a little time for things to catch up
  sleep $ milliSeconds 250
  nsend "job2" ()

  r2 <- waitTimeout (within 2 Seconds) h2
  r1 <- waitTimeout (within 2 Seconds) h1
  stash result (r1, r2)

-- MathDemo tests

testAdd :: ProcessId -> TestResult Double -> Process ()
testAdd pid result = add pid 10 10 >>= stash result

testDivByZero :: ProcessId -> TestResult (Either DivByZero Double) -> Process ()
testDivByZero pid result = divide pid 125 0 >>= stash result

-- Counter tests

testCounterCurrentState :: ProcessId -> TestResult Int -> Process ()
testCounterCurrentState pid result = getCount pid >>= stash result

testCounterIncrement :: ProcessId -> TestResult Int -> Process ()
testCounterIncrement pid result = do
  6 <- incCount pid
  7 <- incCount pid
  getCount pid >>= stash result

testCounterExceedsLimit :: ProcessId -> TestResult Bool -> Process ()
testCounterExceedsLimit pid result = do
  mref <- monitor pid
  7 <- getCount pid

  -- exceed the limit
  3 `times` (void $ incCount pid)

  -- this time we should fail
  _ <- (incCount pid)
         `catchExit` \_ (TerminateOther _) -> return 1

  r <- receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\(ProcessMonitorNotification _ _ r') -> return r')
    ]
  stash result (r == DiedNormal)

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport myRemoteTable
  mpid <- newEmptyMVar
  _ <- forkProcess localNode $ launchMathServer >>= stash mpid
  pid <- takeMVar mpid
  cpid <- newEmptyMVar
  _ <- forkProcess localNode $ startCounter 5 >>= stash cpid
  counter <- takeMVar cpid
  return [
        testGroup "basic server functionality" [
            testCase "basic call with explicit server reply"
            (delayedAssertion
             "expected a response from the server"
             localNode (Just "foo") testBasicCall)
          , testCase "basic call with implicit server reply"
            (delayedAssertion
             "expected n * 2 back from the server"
             localNode (Just 4) testBasicCall_)
          , testCase "basic cast with manual send and explicit server continue"
            (delayedAssertion
             "expected pong back from the server"
             localNode (Just "pong") testBasicCast)
          , testCase "cast and explicit server timeout"
            (delayedAssertion
             "expected the server to stop after the timeout"
             localNode (Just (TerminateOther "timeout")) testControlledTimeout)
          , testCase "unhandled input when policy = Terminate"
            (delayedAssertion
             "expected the server to stop upon receiving unhandled input"
             localNode (Just (TerminateOther "UnhandledInput"))
             testTerminatePolicy)
          , testCase "unhandled input when policy = Drop"
            (delayedAssertion
             "expected the server to ignore unhandled input and exit normally"
             localNode (Just TerminateNormal) testDropPolicy)
          , testCase "unhandled input when policy = DeadLetter"
            (delayedAssertion
             "expected the server to forward unhandled messages"
             localNode (Just ("UNSOLICITED_MAIL", 500 :: Int))
             testDeadLetterPolicy)
          , testCase "incoming messages are ignored whilst hibernating"
            (delayedAssertion
             "expected the server to remain in hibernation"
             localNode True testHibernation)
          , testCase "long running call cancellation"
            (delayedAssertion "expected to get AsyncCancelled"
             localNode True testKillMidCall)
          , testCase "simple exit handling"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode (Just TerminateShutdown) testSimpleErrorHandling)
          , testCase "alternative exit handlers"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode (Just TerminateShutdown) testAlternativeErrorHandling)
          ]
        , testGroup "simple pool examples" [
            testCase "each task execution blocks the caller"
              (delayedAssertion
               "expected the server to return the task outcome"
               localNode (AsyncDone (Right "foobar")) testSimplePoolJobBlocksCaller)
          , testCase "only 'max' tasks can proceed at any time"
              (delayedAssertion
               "expected the server to block the second job until the first was released"
               localNode
               (Just (AsyncDone (Right "foo")),
                Just (AsyncDone (Right "bar"))) testJobQueueSizeLimiting)
          ]
        , testGroup "math server examples" [
            testCase "error (Left) returned from x / 0"
              (delayedAssertion
               "expected the server to return DivByZero"
               localNode (Left DivByZero) (testDivByZero pid))
          , testCase "10 + 10 = 20"
              (delayedAssertion
               "expected the server to return DivByZero"
               localNode 20 (testAdd pid))
          ]
        , testGroup "counter server examples" [
            testCase "initial counter state = 5"
              (delayedAssertion
               "expected the server to return the initial state of 5"
               localNode 5 (testCounterCurrentState counter))
          , testCase "increment counter twice"
              (delayedAssertion
               "expected the server to return the incremented state as 7"
               localNode 7 (testCounterIncrement counter))
          , testCase "exceed counter limits"
            (delayedAssertion
             "expected the server to terminate once the limit was exceeded"
             localNode True (testCounterExceedsLimit counter))
          ]
      ]

main :: IO ()
main = testMain $ tests

