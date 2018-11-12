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

  kill publisher "finished"
  kill consumer  "finished"

testAgentDualInput :: TestResult (Maybe Int) -> Process ()
testAgentDualInput result = do
  (sp, rp) <- newChan
  _ <- mxAgent (MxAgentId "sum-agent") (0 :: Int) [
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

testAgentPrioritisation :: TestResult [String] -> Process ()
testAgentPrioritisation result = do

  -- TODO: this isn't really testing how we /prioritise/ one source
  -- over another at all, but I've not yet figured out the right way
  -- to do so, since we're at the whim of the scheduler with regards
  -- the timeliness of nsend versus mxNotify anyway.

  let name = "prioritising-agent"
  (sp, rp) <- newChan
  void $ mxAgent (MxAgentId name) ["first"] [
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

testAgentMailboxHandling :: TestResult (Maybe ()) -> Process ()
testAgentMailboxHandling result = do
  (sp, rp) <- newChan
  agent <- mxAgent (MxAgentId "listener-agent") () [
      mxSink $ \() -> (liftMX $ sendChan sp ()) >> mxReady
    ]

  nsend "listener-agent" ()

  stash result =<< receiveChanTimeout 1000000 rp
  kill agent "finished"

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

testMxMonitorEvents :: Process ()
testMxMonitorEvents = do

  {- This test only deals with the local case, to ensure that we are being
     notified in the expected order - the remote cases related to the
     behaviour of the node controller are contained in the CH test suite. -}

  let label = "testMxMonitorEvents"
  let agentLabel = "listener-agent"
  let delay = 1000000
  (regChan, regSink) <- newChan
  (unRegChan, unRegSink) <- newChan
  agent <- mxAgent (MxAgentId agentLabel) () [
      mxSink $ \ev -> do
        case ev of
          MxRegistered pid label
            | label /= agentLabel -> liftMX $ sendChan regChan (label, pid)
          MxUnRegistered pid label
            | label /= agentLabel -> liftMX $ sendChan unRegChan (label, pid)
          _                        -> return ()
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

tests :: TestTransport -> IO [Test]
tests TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
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
        testCase "Monitor Events"
          (runProcess node1 testMxMonitorEvents)
      ]
    ]
