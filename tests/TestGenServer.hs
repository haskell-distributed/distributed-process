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
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.GenProcess
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

data GetState = GetState
  deriving (Typeable, Show, Eq)
$(derive makeBinary ''GetState)

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
  3 `times` (incCount pid >> return ())

  -- this time we should fail
  _ <- (incCount pid)
         `catchExit` \_ (TerminateOther _) -> return 1

  r <- receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\(ProcessMonitorNotification _ _ r') -> return r')
    ]
  stash result (r == DiedNormal)

-- utilities

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
        dispatchers = [
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

-- workerPool :: Process ProcessId
-- workerPool =
--   let b = defaultProcess {
--         dispatchers = [
--              handleCast (\_ new -> continue new)
--            , handleCall (\s GetState -> reply s s)
--            ]
--         } :: ProcessDefinition String
--   in spawnLocal $ start () init' b >> return ()
--   where init' :: () -> Process (InitResult String)
--         init' = const (return $ InitOk () Infinity)

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport initRemoteTable
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

