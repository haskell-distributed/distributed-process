{-# LANGUAGE DeriveGeneric #-}
module Control.Distributed.Process.Tests.Mx (tests) where

import Control.Distributed.Process.Tests.Internal.Utils
import Network.Transport.Test (TestTransport(..))

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Management
  ( MxEvent(..)
  , MxAgentId(..)
  , mxAgent
  , mxSink
  , mxReady
  , mxReceive
  , mxDeactivate
  , liftMX
  , mxGetLocal
  , mxSetLocal
  , mxUpdateLocal
  , mxNotify
  , mxBroadcast
  , mxGetId
  )
import Control.Monad (void)
import Control.Rematch (equalTo)
import Data.Binary
import Data.List (find, sort)
import Data.Maybe (isJust)
import Data.Typeable
import GHC.Generics
#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, log)
#endif

import Test.Framework
  ( Test
  , testGroup
  )
import Test.Framework.Providers.HUnit (testCase)

data Publish = Publish
  deriving (Typeable, Generic, Eq)

instance Binary Publish where

awaitExit :: ProcessId -> Process ()
awaitExit pid =
  withMonitorRef pid $ \ref -> do
      receiveWait
        [ matchIf (\(ProcessMonitorNotification r _ _) -> r == ref)
                  (\_ -> return ())
        ]
  where
    withMonitorRef pid = bracket (monitor pid) unmonitor

testAgentBroadcast :: TestResult () -> Process ()
testAgentBroadcast result = do
  (resultSP, resultRP) <- newChan :: Process (SendPort (), ReceivePort ())

  publisher <- mxAgent (MxAgentId "publisher-agent") () [
      mxSink $ \() -> mxBroadcast Publish >> mxReady
    ]

  consumer  <- mxAgent (MxAgentId "consumer-agent") () [
      mxSink $ \Publish -> (liftMX $ sendChan resultSP ()) >> mxReady
    ]

  mxNotify ()
  -- Once the publisher has seen our message, it will broadcast the Publish
  -- and the consumer will see that and send the result to our typed channel.
  stash result =<< receiveChan resultRP

  kill publisher "finished" >> awaitExit publisher
  kill consumer  "finished" >> awaitExit consumer

testAgentDualInput :: TestResult (Maybe Int) -> Process ()
testAgentDualInput result = do
  (sp, rp) <- newChan
  s <- mxAgent (MxAgentId "sum-agent") (0 :: Int) [
        mxSink $ (\(i :: Int) -> do
                     mxSetLocal . (+i) =<< mxGetLocal
                     i' <- mxGetLocal
                     if i' == 15
                        then do mxGetLocal >>= liftMX . sendChan sp
                                mxDeactivate "finished"
                        else mxReady)
    ]

  mxNotify          (1 :: Int)
  nsend "sum-agent" (3 :: Int)
  mxNotify          (2 :: Int)
  nsend "sum-agent" (4 :: Int)
  mxNotify          (5 :: Int)

  stash result =<< receiveChanTimeout 10000000 rp
  awaitExit s

testAgentPrioritisation :: TestResult [String] -> Process ()
testAgentPrioritisation result = do

  -- TODO: this isn't really testing how we /prioritise/ one source
  -- over another at all, but I've not yet figured out the right way
  -- to do so, since we're at the whim of the scheduler with regards
  -- the timeliness of nsend versus mxNotify anyway.

  let name = "prioritising-agent"
  (sp, rp) <- newChan
  s <- mxAgent (MxAgentId name) ["first"] [
         mxSink (\(s :: String) -> do
                   mxUpdateLocal ((s:))
                   st <- mxGetLocal
                   case length st of
                     n | n == 5 -> do liftMX $ sendChan sp st
                                      mxDeactivate "finished"
                     _          -> mxReceive  -- go to the mailbox
                   )
    ]

  nsend name "second"
  mxNotify "third"
  mxNotify "fourth"
  nsend name "fifth"

  stash result . sort =<< receiveChan rp
  awaitExit s

testAgentMailboxHandling :: TestResult (Maybe ()) -> Process ()
testAgentMailboxHandling result = do
  (sp, rp) <- newChan
  agent <- mxAgent (MxAgentId "mailbox-agent") () [
      mxSink $ \() -> (liftMX $ sendChan sp ()) >> mxReady
    ]

  nsend "mailbox-agent" ()

  stash result =<< receiveChanTimeout 1000000 rp
  kill agent "finished" >> awaitExit agent

testAgentEventHandling :: TestResult Bool -> Process ()
testAgentEventHandling result = do
  let initState = [] :: [MxEvent]
  agentPid <- mxAgent (MxAgentId "lifecycle-listener-agent") initState [
      (mxSink $ \ev -> do
         st <- mxGetLocal
         let act =
               case ev of
                 (MxSpawned _)       -> mxSetLocal (ev:st)
                 (MxProcessDied _ _) -> mxSetLocal (ev:st)
                 _                   -> return ()
         act >> mxReady),
      (mxSink $ \(ev, sp :: SendPort Bool) -> do
          st <- mxGetLocal
          let found =
                case ev of
                  MxSpawned p ->
                    isJust $ find (\ev' ->
                                    case ev' of
                                      (MxSpawned p') -> p' == p
                                      _              -> False) st
                  MxProcessDied p r ->
                    isJust $ find (\ev' ->
                                    case ev' of
                                      (MxProcessDied p' r') -> p' == p && r == r'
                                      _                     -> False) st
                  _ -> False
          liftMX $ sendChan sp found
          mxReady)
    ]

  _ <- monitor agentPid
  (sp, rp) <- newChan
  pid <- spawnLocal $ sendChan sp ()
  () <- receiveChan rp

  -- By waiting for a monitor notification, we have a
  -- higher probably that the agent has seen
  monitor pid
  receiveWait [ match (\(ProcessMonitorNotification _ _ _) -> return ()) ]

  (replyTo, reply) <- newChan :: Process (SendPort Bool, ReceivePort Bool)
  mxNotify (MxSpawned pid, replyTo)
  mxNotify (MxProcessDied pid DiedNormal, replyTo)

  seenAlive <- receiveChan reply
  seenDead  <- receiveChan reply

  stash result $ seenAlive && seenDead
  kill agentPid "test-complete" >> awaitExit agentPid

testMxRegEvents :: TestResult () -> Process ()
testMxRegEvents result = do
  {- This test only deals with the local case, to ensure that we are being
     notified in the expected order - the remote cases related to the
     behaviour of the node controller are contained in the CH test suite. -}
  ensure (stash result ()) $ do
    let label = "testMxRegEvents"
    let agentLabel = "mxRegEvents-agent"
    let delay = 1000000
    (regChan, regSink) <- newChan
    (unRegChan, unRegSink) <- newChan
    agent <- mxAgent (MxAgentId agentLabel) () [
        mxSink $ \ev -> do
          case ev of
            MxRegistered pid label'
              | label' == label -> liftMX $ sendChan regChan (label', pid)
            MxUnRegistered pid label'
              | label' == label -> liftMX $ sendChan unRegChan (label', pid)
            _                   -> return ()
          mxReady
      ]

    p1 <- spawnLocal expect
    p2 <- spawnLocal expect

    register label p1
    reg1 <- receiveChanTimeout delay regSink
    reg1 `shouldBe` equalTo (Just (label, p1))

    unregister label
    unreg1 <- receiveChanTimeout delay unRegSink
    unreg1 `shouldBe` equalTo (Just (label, p1))

    register label p2
    reg2 <- receiveChanTimeout delay regSink
    reg2 `shouldBe` equalTo (Just (label, p2))

    reregister label p1
    unreg2 <- receiveChanTimeout delay unRegSink
    unreg2 `shouldBe` equalTo (Just (label, p2))

    reg3 <- receiveChanTimeout delay regSink
    reg3 `shouldBe` equalTo (Just (label, p1))

    mapM_ (flip kill $ "test-complete") [agent, p1, p2]
    awaitExit agent

testMxRegMon :: LocalNode -> TestResult () -> Process ()
testMxRegMon remoteNode result = do
  ensure (stash result ()) $ do
    -- ensure that when a registered process dies, we get a notification that
    -- it has been unregistered as well as seeing the name get removed
    let label1 = "aaaaa"
    let label2 = "bbbbb"
    let isValid l = l == label1 || l == label2
    let agentLabel = "mxRegMon-agent"
    let delay = 1000000
    (regChan, regSink) <- newChan
    (unRegChan, unRegSink) <- newChan
    agent <- mxAgent (MxAgentId agentLabel) () [
        mxSink $ \ev -> do
          case ev of
            MxRegistered pid label
              | isValid label -> liftMX $ sendChan regChan (label, pid)
            MxUnRegistered pid label
              | isValid label -> liftMX $ sendChan unRegChan (label, pid)
            _                 -> return ()
          mxReady
      ]

    (sp, rp) <- newChan
    liftIO $ forkProcess remoteNode $ do
      getSelfPid >>= sendChan sp
      expect :: Process ()

    p1 <- receiveChan rp

    register label1 p1
    reg1 <- receiveChanTimeout delay regSink
    reg1 `shouldBe` equalTo (Just (label1, p1))

    register label2 p1
    reg2 <- receiveChanTimeout delay regSink
    reg2 `shouldBe` equalTo (Just (label2, p1))

    n1 <- whereis label1
    n1 `shouldBe` equalTo (Just p1)

    n2 <- whereis label2
    n2 `shouldBe` equalTo (Just p1)

    kill p1 "goodbye"

    unreg1 <- receiveChanTimeout delay unRegSink
    unreg2 <- receiveChanTimeout delay unRegSink

    let evts = [unreg1, unreg2]
    -- we can't rely on the order of the values in the node controller's
    -- map (it's either racy to do so, or no such guarantee exists for Data.Map),
    -- so we simply verify that we received the un-registration events we expect
    evts `shouldContain` (Just (label1, p1))
    evts `shouldContain` (Just (label2, p1))

    kill agent "test-complete" >> awaitExit agent

ensure :: Process () -> Process () -> Process ()
ensure = flip finally

tests :: TestTransport -> IO [Test]
tests TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  return [
      testGroup "Mx Agents" [
          testCase "Event Handling"
              (delayedAssertion
               "expected True, but events where not as expected"
               node1 True testAgentEventHandling)
        , testCase "Inter-Agent Broadcast"
              (delayedAssertion
               "expected (), but no broadcast was received"
               node1 () testAgentBroadcast)
        , testCase "Agent Mailbox Handling"
              (delayedAssertion
               "expected (Just ()), but no regular (mailbox) input was handled"
               node1 (Just ()) testAgentMailboxHandling)
        , testCase "Agent Dual Input Handling"
              (delayedAssertion
               "expected sum = 15, but the result was Nothing"
               node1 (Just 15 :: Maybe Int) testAgentDualInput)
        , testCase "Agent Input Prioritisation"
              (delayedAssertion
               "expected [first, second, third, fourth, fifth], but result diverged"
               node1 (sort ["first", "second",
                            "third", "fourth",
                            "fifth"]) testAgentPrioritisation)
      ]
    , testGroup "Mx Events" [
        testCase "Name Registration Events"
          (delayedAssertion
           "expected registration events to map to the correct ProcessId"
           node1 () testMxRegEvents)
      , testCase "Post Death Name UnRegistration Events"
          (delayedAssertion
           "expected process deaths to result in unregistration events"
           node1 () (testMxRegMon node2))
      ]
    ]
