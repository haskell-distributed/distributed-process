{-# LANGUAGE ScopedTypeVariables #-}

-- NB: this module contains tests for the GenProcess /and/ GenServer API.

module Main where

-- import Control.Concurrent.MVar
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.GenProcess
import Control.Distributed.Process.Platform.Time

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
  pid <- server
  callTimeout pid "foo" (within 5 Seconds) >>= stash result

testBasicCall_ :: TestResult (Maybe Int) -> Process ()
testBasicCall_ result = do
  pid <- server
  callTimeout pid (2 :: Int) (within 5 Seconds) >>= stash result

testBasicCast :: TestResult (Maybe String) -> Process ()
testBasicCast result = do
  self <- getSelfPid
  pid <- server
  cast pid ("ping", self)
  expectTimeout (after 3 Seconds) >>= stash result

server :: Process ProcessId
server =
  let s = statelessProcess {
        dispatchers = [
              handleCall    (\s' (m :: String) -> reply m s')  -- state passed
            , handleCall_   (\(n :: Int) -> return (n * 2))    -- "stateless"

            , handleCast    (\s' ("ping",                      -- regular cast
                                    pid :: ProcessId) ->
                                        send pid "pong" >> continue s')

                                                               -- "stateless"
            , handleCastIf_ (\(c :: String, _ :: Delay) -> c == "timeout")
                            (\("timeout", Delay d) -> timeoutAfter_ d)

            , action        (\"stop" -> stop_ TerminateNormal)
          ]
      , infoHandlers = []
      , unhandledMessagePolicy = Terminate
      , timeoutHandler   = \_ _ -> stop $ TerminateOther "timeout"
    }
  in spawnLocal $ start () startup s >> return ()
  where startup :: InitHandler () ()
        startup _ = return $ InitOk () Infinity

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport initRemoteTable
  -- mv <- newEmptyMVar
  -- _ <- forkProcess localNode $ launchMathServer >>= stash mv
  -- sid <- takeMVar mv
  return [
        testGroup "Handling async results" [
--          mathTest "simple addition"
--                   "10 + 10 = 20"
--                   localNode sid 10 10 opAdd
            testCase "basic call"
            (delayedAssertion
             "expected a response from the server"
             localNode (Just "foo") testBasicCall)
          , testCase "basic call_"
            (delayedAssertion
             "expected n * 2 back from the server"
             localNode (Just 4) testBasicCall_)
          , testCase "basic cast"
            (delayedAssertion
             "expected pong back from the server"
             localNode (Just "pong") testBasicCast)
        ]
      ]

main :: IO ()
main = testMain $ tests
