{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform
  ( Routable(..)
  , Resolvable(..)
  , Observable(..)
  , Channel
  , spawnSignalled
  )
import qualified Control.Distributed.Process.Platform (__remoteTable)
import Control.Distributed.Process.Platform.Execution.EventManager hiding (start)
import Control.Distributed.Process.Platform.Execution.Exchange
import Control.Distributed.Process.Platform.Execution.Exchange.Router
import qualified Control.Distributed.Process.Platform.Execution.EventManager as EventManager
  ( start
  )
-- import Control.Distributed.Process.Platform.Execution.Exchange.Broadcast (monitor)
import Control.Distributed.Process.Platform.Test
-- import Control.Distributed.Process.Platform.Time
-- import Control.Distributed.Process.Platform.Timer
import Control.Monad (void)
import Control.Rematch (equalTo)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop)
#endif

import Data.Maybe (catMaybes)
import qualified Network.Transport as NT
import Test.Framework as TF (testGroup, Test)
import Test.Framework.Providers.HUnit
import TestUtils

testKeyBasedRouting :: TestResult Bool -> Process ()
testKeyBasedRouting result = do
  (sp, rp) <- newChan :: Process (Channel Int)
  rex <- messageKeyRouter PayloadOnly

  -- Since the /router/ doesn't offer a syncrhonous start
  -- option, we use spawnSignalled to get the same effect,
  -- making it more likely (though it's not guaranteed) that
  -- the spawned process will be bound to the routing exchange
  -- prior to our evaluating 'routeMessage' below.
  void $ spawnSignalled (bindKey "foobar" rex) $ const $ do
    receiveWait [ match (\(s :: Int) -> sendChan sp s) ]

  routeMessage rex (createMessage "foobar" [] (123 :: Int))
  stash result . (== (123 :: Int)) =<< receiveChan rp

testSimpleEventHandling :: TestResult Bool -> Process ()
testSimpleEventHandling result = do
  (sp, rp) <- newChan
  (sigStart, recvStart) <- newChan
  em <- EventManager.start
  Just pid <- resolve em
  void $ monitor pid

  -- Note that in our init (state) function, we write a "start signal"
  -- here; Without a start signal, the message sent to the event manager
  -- (via notify) would race with the addHandler registration.
  pid <- addHandler em (myHandler sp) (sendChan sigStart ())
  link pid

  () <- receiveChan recvStart

  notify em ("hello", "event", "manager") -- cast message
  r <- receiveTimeout 100000000 [
      matchChan rp return
    , match (\(ProcessMonitorNotification _ _ r) -> die "ServerDied")
    ]
  case r of
    Just ("hello", "event", "manager") -> stash result True
    _                                  -> stash result False

myHandler :: SendPort (String, String, String)
          -> ()
          -> (String, String, String)
          -> Process ()
myHandler sp s m@(_, _, _) = sendChan sp m >> return s

myRemoteTable :: RemoteTable
myRemoteTable =
  Control.Distributed.Process.Platform.__remoteTable initRemoteTable

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport myRemoteTable
  return [
        testGroup "Event Manager"
        [
          testCase "Simple Event Handlers"
          (delayedAssertion
           "Expected the handler to run" localNode True testSimpleEventHandling)
--        , testCase "Simple Event Handlers 2"
--          (delayedAssertion
--           "Expected the handler to run" localNode True testIt)
        ]

      , testGroup "Router"
        [
          testCase "Key Based Routing"
          (delayedAssertion
           "Expected the handler to run" localNode True testKeyBasedRouting)
--        , testCase "Simple Event Handlers 2"
--          (delayedAssertion
--           "Expected the handler to run" localNode True testIt)
        ]
    ]

main :: IO ()
main = testMain $ tests

