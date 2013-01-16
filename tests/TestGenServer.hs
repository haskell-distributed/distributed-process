{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ImpredicativeTypes  #-}

-- NB: this module contains tests for the GenProcess /and/ GenServer API.

module Main where

import Control.Concurrent.MVar
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.GenProcess
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer

import Data.Binary()
import Data.Typeable()
import MathsDemo

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils

import qualified Network.Transport as NT

type OpExpr = (Double -> Double -> Double)
data Op = Add OpExpr | Div OpExpr

opAdd :: Op
opAdd = Add (+)

opDiv :: Op
opDiv = Div (/)

expr :: Op -> OpExpr
expr (Add f) = f
expr (Div f) = f

mathTest :: String
         -> String
         -> LocalNode
         -> ProcessId
         -> Double
         -> Double
         -> Op
         -> Test
mathTest t n l sid x y op = let fn = expr op in do
    testCase t (delayedAssertion n l (x `fn` y) (proc sid x y op))
  where proc s x' y' (Add _) result = add s x' y' >>= stash result
        proc s x' y' (Div _) result = divide s x' y' >>= stash result

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

  sleep $ seconds 1
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
              handleCall    (\s' (m :: String) -> reply m s')
            , handleCall_   (\(n :: Int) -> return (n * 2))    -- "stateless"

            , handleCast    (\s' ("ping", pid :: ProcessId) ->
                                 send pid "pong" >> continue s')
            , handleCastIf_ (\(c :: String, _ :: Delay) -> c == "timeout")
                            (\("timeout", Delay d) -> timeoutAfter_ d)
            , action        (\("stop") -> stop_ TerminateNormal)
          ]
      , unhandledMessagePolicy = policy
      , timeoutHandler         = \_ _ -> stop $ TerminateOther "timeout"
    }
  in do
    exitReason <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
      start () (statelessInit Infinity) s >>= stash exitReason
    return (pid, exitReason)

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport initRemoteTable
  -- _ <- forkProcess localNode $ launchMathServer >>= stash mv
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
             localNode (Just (TerminateOther "UNHANDLED_INPUT"))
             testTerminatePolicy)
          , testCase "unhandled input when policy = Drop"
            (delayedAssertion
             "expected the server to ignore unhandled input and exit normally"
             localNode (Just TerminateNormal) testDropPolicy)
          , testCase "unhandled input when policy = Drop"
            (delayedAssertion
             "expected the server to forward unhandled messages"
             localNode (Just ("UNSOLICITED_MAIL", 500 :: Int))
             testDeadLetterPolicy)
          ]
      ]

main :: IO ()
main = testMain $ tests
