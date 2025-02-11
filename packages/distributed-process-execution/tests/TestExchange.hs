{-# LANGUAGE CPP                   #-}
{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Main where

import Control.Distributed.Process hiding (monitor)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Execution.EventManager hiding (start)
import qualified Control.Distributed.Process.Extras
import Control.Distributed.Process.Execution.Exchange
import Control.Distributed.Process.Extras.Internal.Types
import Control.Distributed.Process.Extras.Internal.Primitives
import qualified Control.Distributed.Process.Execution.EventManager as EventManager
  ( start
  )
import Control.Distributed.Process.SysTest.Utils
import Control.Monad (void, forM, forever)

import Prelude hiding (drop)
import Network.Transport.TCP
import qualified Network.Transport as NT
import Test.Tasty (defaultMain, testGroup, TestTree)
import Test.Tasty.HUnit (assertEqual, assertBool, testCase)

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
  liftIO $ do

    assertBool mempty $ Just (p1, Left "Hello") `elem` received
    assertBool mempty $ Just (p3, Left "Hello") `elem` received
    assertBool mempty $ Just (p1, Right (123 :: Int)) `elem` received
    assertBool mempty $ Just (p3, Right (123 :: Int)) `elem` received

    -- however the bindings for 'def' never fired
    assertBool mempty $ Nothing `elem` received
    assertBool mempty $ Just (p2, Left "Hello") `notElem` received
    assertBool mempty $ Just (p2, Right (123 :: Int)) `notElem` received
 
    -- none of the bindings should have examined the headers!
    assertBool mempty $ Just (p1, Left "Goodbye") `notElem` received
    assertBool mempty $ Just (p2, Left "Goodbye") `notElem` received
    assertBool mempty $ Just (p3, Left "Goodbye") `notElem` received

testHeaderBasedRouting :: TestResult () -> Process ()
testHeaderBasedRouting result = do
  stash result ()  -- we don't rely on the test result for assertions...
  (sp, rp) <- newChan
  rex <- headerContentRouter PayloadOnly "x-name"
  let recv = const $ forever $ receiveWait [
          match (\(s :: String) -> getSelfPid >>= \us -> sendChan sp (us, Left s))
        , match (\(i :: Int) -> getSelfPid >>= \us -> sendChan sp (us, Right i))
        ]

  us <- getSelfPid
  p1 <- spawnSignalled (link us >> bindHeader "x-name" "yellow" rex) recv
  p2 <- spawnSignalled (link us >> bindHeader "x-name" "red"    rex) recv
  _  <- spawnSignalled (link us >> bindHeader "x-type" "fast"   rex) recv

  -- publish 2 messages with the routing-key set to 'abc'
  routeMessage rex (createMessage "" [("x-name", "yellow")] "Hello")
  routeMessage rex (createMessage "" [("x-name", "yellow")] (123 :: Int))
  routeMessage rex (createMessage "" [("x-name", "red")]    (456 :: Int))
  routeMessage rex (createMessage "" [("x-name", "red")]    (789 :: Int))
  routeMessage rex (createMessage "" [("x-type", "fast")]   "Goodbye")

  -- route another message with the 'abc' value a header (should be ignored)
  routeMessage rex (createMessage "" [("abc", "abc")] "FooBar")

  received <- forM (replicate 5 us) (const $ receiveChanTimeout 1000 rp)

  -- all bindings fired correctly
  liftIO $ do
    assertBool mempty $ Just (p1, Left "Hello") `elem` received
    assertBool mempty $ Just (p1, Left "Hello") `elem` received
    assertBool mempty $ Just (p1, Right (123 :: Int)) `elem` received
    assertBool mempty $ Just (p2, Right (456 :: Int)) `elem` received
    assertBool mempty $ Just (p2, Right (789 :: Int)) `elem` received
    assertBool mempty $ Nothing `elem` received

  -- simple check that no other bindings have fired
  liftIO $ assertEqual mempty 5 (length received)

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
  pid' <- addHandler em (myHandler sp) (sendChan sigStart ())
  link pid'

  () <- receiveChan recvStart

  notify em ("hello", "event", "manager") -- cast message
  r <- receiveTimeout 100000000 [
      matchChan rp return
    , match (\(ProcessMonitorNotification _ _ _) -> die "ServerDied")
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
  Control.Distributed.Process.Extras.__remoteTable initRemoteTable

tests :: NT.Transport  -> IO TestTree
tests transport = do
  localNode <- newLocalNode transport myRemoteTable
  return $ testGroup "" [
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
        , testCase "Header Based Selective Routing"
          (delayedAssertion "Expected only the matching routes to run"
           localNode () testHeaderBasedRouting)
        ]
    ]

main :: IO ()
main = testMain $ tests

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO TestTree) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals (defaultTCPAddr "127.0.0.1" "10501") defaultTCPParameters
  testData <- builder transport
  defaultMain testData
