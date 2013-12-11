{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE TemplateHaskell     #-}

module Main where

import Control.Concurrent.MVar
import Control.Exception (SomeException)
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform hiding (__remoteTable, monitor, send, nsend)
import Control.Distributed.Process.Platform.ManagedProcess
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable()

import MathsDemo
import Counter
import qualified SafeCounter as SafeCounter

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils
import ManagedProcessCommon

import qualified Network.Transport as NT
import Control.Monad (void)

-- utilities

server :: Process (ProcessId, (MVar ExitReason))
server = mkServer Terminate

mkServer :: UnhandledMessagePolicy
         -> Process (ProcessId, (MVar ExitReason))
mkServer policy =
  let s = standardTestServer policy
  in do
    exitReason <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
       catch  ((serve () (statelessInit Infinity) s >> stash exitReason ExitNormal)
                `catchesExit` [
                    (\_ msg -> do
                      mEx <- unwrapMessage msg :: Process (Maybe ExitReason)
                      case mEx of
                        Nothing -> return Nothing
                        Just r  -> stash exitReason r >>= return . Just
                    )
                 ])
              (\(e :: SomeException) -> stash exitReason $ ExitOther (show e))
    return (pid, exitReason)

explodingServer :: ProcessId
                -> Process (ProcessId, MVar ExitReason)
explodingServer pid =
  let srv = explodingTestProcess pid
  in do
    exitReason <- liftIO $ newEmptyMVar
    spid <- spawnLocal $ do
       catch  (serve () (statelessInit Infinity) srv >> stash exitReason ExitNormal)
              (\(e :: SomeException) -> stash exitReason $ ExitOther (show e))
    return (spid, exitReason)

testCallReturnTypeMismatchHandling :: TestResult Bool -> Process ()
testCallReturnTypeMismatchHandling result =
  let procDef = statelessProcess {
                    apiHandlers = [
                      handleCall (\s (m :: String) -> reply m s)
                    ]
                    , unhandledMessagePolicy = Terminate
                    } in do
    pid <- spawnLocal $ serve () (statelessInit Infinity) procDef
    res <- safeCall pid "hello buddy" :: Process (Either ExitReason ())
    case res of
      Left  (ExitOther _) -> stash result True
      _                   -> stash result False

testChannelBasedService :: TestResult Bool -> Process ()
testChannelBasedService result =
  let procDef = statelessProcess {
                    apiHandlers = [
                      handleRpcChan (\s p (m :: String) ->
                                   replyChan p m >> continue s)
                    ]
                    } in do
    pid <- spawnLocal $ serve () (statelessInit Infinity) procDef
    echo <- syncCallChan pid "hello"
    stash result (echo == "hello")
    kill pid "done"

-- MathDemo tests

testAdd :: ProcessId -> TestResult Double -> Process ()
testAdd pid result = add pid 10 10 >>= stash result

testBadAdd :: ProcessId -> TestResult (Either ExitReason Int) -> Process ()
testBadAdd pid result = safeCall pid (Add 10 10) >>= stash result

testDivByZero :: ProcessId -> TestResult (Either DivByZero Double) -> Process ()
testDivByZero pid result = divide pid 125 0 >>= stash result

-- SafeCounter tests

testSafeCounterCurrentState :: ProcessId -> TestResult Int -> Process ()
testSafeCounterCurrentState pid result =
  SafeCounter.getCount pid >>= stash result

testSafeCounterIncrement :: ProcessId -> TestResult Int -> Process ()
testSafeCounterIncrement pid result = do
  5 <- SafeCounter.getCount pid
  SafeCounter.resetCount pid
  1 <- SafeCounter.incCount pid
  2 <- SafeCounter.incCount pid
  SafeCounter.getCount pid >>= stash result

-- Counter tests

testCounterCurrentState :: TestResult Int -> Process ()
testCounterCurrentState result = do
  pid <- Counter.startCounter 5
  getCount pid >>= stash result

testCounterIncrement :: TestResult Bool -> Process ()
testCounterIncrement result = do
  pid <- Counter.startCounter 1
  n <- getCount pid
  2 <- incCount pid
  3 <- incCount pid
  getCount pid >>= \n' -> stash result (n' == (n + 2))

testCounterExceedsLimit :: TestResult Bool -> Process ()
testCounterExceedsLimit result = do
  pid <- Counter.startCounter 1
  mref <- monitor pid

  -- exceed the limit
  9 `times` (void $ incCount pid)

  -- this time we should fail
  _ <- (incCount pid)
         `catchExit` \_ (_ :: ExitReason) -> return 0

  r <- receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              (\(ProcessMonitorNotification _ _ r') -> return r')
    ]
  stash result (r /= DiedNormal)

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport initRemoteTable
  mpid <- newEmptyMVar
  _ <- forkProcess localNode $ launchMathServer >>= stash mpid
  pid <- takeMVar mpid
  scpid <- newEmptyMVar
  _ <- forkProcess localNode $ SafeCounter.startCounter 5 >>= stash scpid
  safeCounter <- takeMVar scpid
  return [
        testGroup "basic server functionality" [
            testCase "basic call with explicit server reply"
            (delayedAssertion
             "expected a response from the server"
             localNode (Just "foo") (testBasicCall $ wrap server))
          , testCase "basic (unsafe) call with explicit server reply"
            (delayedAssertion
             "expected a response from the server"
             localNode (Just "foo") (testUnsafeBasicCall $ wrap server))
          , testCase "basic call with implicit server reply"
            (delayedAssertion
             "expected n * 2 back from the server"
             localNode (Just 4) (testBasicCall_ $ wrap server))
          , testCase "basic (unsafe) call with implicit server reply"
            (delayedAssertion
             "expected n * 2 back from the server"
             localNode (Just 4) (testUnsafeBasicCall_ $ wrap server))
          , testCase "basic cast with manual send and explicit server continue"
            (delayedAssertion
             "expected pong back from the server"
             localNode (Just "pong") (testBasicCast $ wrap server))
          , testCase "basic (unsafe) cast with manual send and explicit server continue"
            (delayedAssertion
             "expected pong back from the server"
             localNode (Just "pong") (testUnsafeBasicCast $ wrap server))
          , testCase "cast and explicit server timeout"
            (delayedAssertion
             "expected the server to stop after the timeout"
             localNode (Just $ ExitOther "timeout") (testControlledTimeout $ wrap server))
          , testCase "(unsafe) cast and explicit server timeout"
            (delayedAssertion
             "expected the server to stop after the timeout"
             localNode (Just $ ExitOther "timeout") (testUnsafeControlledTimeout $ wrap server))
          , testCase "unhandled input when policy = Terminate"
            (delayedAssertion
             "expected the server to stop upon receiving unhandled input"
             localNode (Just $ ExitOther "UnhandledInput")
             (testTerminatePolicy $ wrap server))
          , testCase "(unsafe) unhandled input when policy = Terminate"
            (delayedAssertion
             "expected the server to stop upon receiving unhandled input"
             localNode (Just $ ExitOther "UnhandledInput")
             (testUnsafeTerminatePolicy $ wrap server))
          , testCase "unhandled input when policy = Drop"
            (delayedAssertion
             "expected the server to ignore unhandled input and exit normally"
             localNode Nothing (testDropPolicy $ wrap (mkServer Drop)))
          , testCase "(unsafe) unhandled input when policy = Drop"
            (delayedAssertion
             "expected the server to ignore unhandled input and exit normally"
             localNode Nothing (testUnsafeDropPolicy $ wrap (mkServer Drop)))
          , testCase "unhandled input when policy = DeadLetter"
            (delayedAssertion
             "expected the server to forward unhandled messages"
             localNode (Just ("UNSOLICITED_MAIL", 500 :: Int))
             (testDeadLetterPolicy $ \p -> mkServer (DeadLetter p)))
          , testCase "(unsafe) unhandled input when policy = DeadLetter"
            (delayedAssertion
             "expected the server to forward unhandled messages"
             localNode (Just ("UNSOLICITED_MAIL", 500 :: Int))
             (testUnsafeDeadLetterPolicy $ \p -> mkServer (DeadLetter p)))
          , testCase "incoming messages are ignored whilst hibernating"
            (delayedAssertion
             "expected the server to remain in hibernation"
             localNode True (testHibernation $ wrap server))
          , testCase "(unsafe) incoming messages are ignored whilst hibernating"
            (delayedAssertion
             "expected the server to remain in hibernation"
             localNode True (testUnsafeHibernation $ wrap server))
          , testCase "long running call cancellation"
            (delayedAssertion "expected to get AsyncCancelled"
             localNode True (testKillMidCall $ wrap server))
          , testCase "(unsafe) long running call cancellation"
            (delayedAssertion "expected to get AsyncCancelled"
             localNode True (testUnsafeKillMidCall $ wrap server))
          , testCase "simple exit handling"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode Nothing (testSimpleErrorHandling $ explodingServer))
          , testCase "(unsafe) simple exit handling"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode Nothing (testUnsafeSimpleErrorHandling $ explodingServer))
          , testCase "alternative exit handlers"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode Nothing (testAlternativeErrorHandling $ explodingServer))
          , testCase "(unsafe) alternative exit handlers"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode Nothing (testUnsafeAlternativeErrorHandling $ explodingServer))
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
          , testCase "10 + 10 does not evaluate to 10 :: Int at all!"
            (delayedAssertion
             "expected the server to return ExitOther..."
             localNode
             (Left $ ExitOther $ "DiedException \"exit-from=" ++ (show pid) ++ "\"")
             (testBadAdd pid))
          ]
        , testGroup "counter server examples" [
            testCase "initial counter state = 5"
              (delayedAssertion
               "expected the server to return the initial state of 5"
               localNode 5 testCounterCurrentState)
          , testCase "increment counter twice"
              (delayedAssertion
               "expected the server to return the incremented state as 7"
               localNode True testCounterIncrement)
          , testCase "exceed counter limits"
            (delayedAssertion
             "expected the server to terminate once the limit was exceeded"
             localNode True testCounterExceedsLimit)
          ]
        , testGroup "safe counter examples" [
            testCase "initial counter state = 5"
              (delayedAssertion
               "expected the server to return the initial state of 5"
               localNode 5 (testSafeCounterCurrentState safeCounter))
          , testCase "increment counter twice"
              (delayedAssertion
               "expected the server to return the incremented state as 7"
               localNode 2 (testSafeCounterIncrement safeCounter))
          ]
      ]

main :: IO ()
main = testMain $ tests

