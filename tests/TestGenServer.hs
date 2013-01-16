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
  self <- getSelfPid
  (pid, exitReason) <- server
  cast pid ("timeout", Delay $ within 1 Seconds)

  -- we *might* end up blocked here, so ensure the test suite doesn't jam!
  killAfter (within 10 Seconds) self "testcast timed out"

  tr <- liftIO $ takeMVar exitReason
  case tr of
    Right r -> stash result (Just r)
    _       -> stash result Nothing

server :: Process ((ProcessId, MVar (Either (InitResult ()) TerminateReason)))
server =
  let s = statelessProcess {
        dispatchers = [
              -- note: state is passed here, as a 'stateless' server is a
              -- server with state = ()
              handleCall    (\s' (m :: String) -> reply m s')
            , handleCall_   (\(n :: Int) -> return (n * 2))    -- "stateless"

            , handleCast    (\s' ("ping", pid :: ProcessId) ->
                                 send pid "pong" >> continue s')
            , handleCastIf_ (\(c :: String, _ :: Delay) -> c == "timeout")
                            (\("timeout", Delay d) -> timeoutAfter_ d)
            , action        (\("stop") -> stop_ TerminateNormal)
          ]
      , unhandledMessagePolicy = Terminate
      , timeoutHandler         = \_ _ -> stop $ TerminateOther "timeout"
    }
  in do
    exitReason <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ (start () startup s) >>= stash exitReason
    return (pid, exitReason)
  where startup :: InitHandler () ()
        startup _ = return $ InitOk () Infinity

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
        ]
      ]

main :: IO ()
main = testMain $ tests
