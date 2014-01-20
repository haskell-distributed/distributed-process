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
import Control.Monad (void, forM, forever)
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

testMultipleRoutes :: TestResult () -> Process ()
testMultipleRoutes result = do
  stash result ()    -- we don't rely on the test result for assertions...
  (sp, rp) <- newChan
  rex <- messageKeyRouter PayloadOnly
  let recv = receiveWait [
          match (\(s :: String) -> getSelfPid >>= \us -> sendChan sp (us, Left s))
        , match (\(i :: Int) -> getSelfPid >>= \us -> sendChan sp (us, Right i))
        ]

  us <- getSelfPid
  p1 <- spawnSignalled (link us >> bindKey "abc" rex) (const $ forever recv)
  p2 <- spawnSignalled (link us >> bindKey "def" rex) (const $ forever recv)
  p3 <- spawnSignalled (link us >> bindKey "abc" rex) (const $ forever recv)

  -- publish 2 messages with the routing-key set to 'abc'
  routeMessage rex (createMessage "abc" [] "Hello")
  routeMessage rex (createMessage "abc" [] (123 :: Int))

  -- route another message with the 'abc' value a header (should be ignored)
  routeMessage rex (createMessage "" [("abc", "abc")] "Goodbye")

  received <- forM (replicate (2 * 3) us) (const $ receiveChanTimeout 1000 rp)

  -- all bindings for 'abc' fired correctly
  received `shouldContain` Just (p1, Left "Hello")
  received `shouldContain` Just (p3, Left "Hello")
  received `shouldContain` Just (p1, Right (123 :: Int))
  received `shouldContain` Just (p3, Right (123 :: Int))

  -- however the bindings for 'def' never fired
  received `shouldContain` Nothing
  received `shouldNotContain` Just (p2, Left "Hello")
  received `shouldNotContain` Just (p2, Right (123 :: Int))

  -- none of the bindings should have examined the headers!
  received `shouldNotContain` Just (p1, Left "Goodbye")
  received `shouldNotContain` Just (p2, Left "Goodbye")
  received `shouldNotContain` Just (p3, Left "Goodbye")

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
          (delayedAssertion "Expected the handler to run"
           localNode True testSimpleEventHandling)
        ]

      , testGroup "Router"
        [
          testCase "Direct Key Routing"
          (delayedAssertion "Expected the sole matching route to run"
           localNode True testKeyBasedRouting)
        , testCase "Key Based Selective Routing"
          (delayedAssertion "Expected only the matching routes to run"
           localNode () testMultipleRoutes)
        ]
    ]

main :: IO ()
main = testMain $ tests

