{-# LANGUAGE DeriveGeneric #-}
module Control.Distributed.Process.Tests.Mx (tests) where

import Control.Distributed.Process.Tests.Internal.Utils
import Network.Transport.Test (TestTransport(..))
import Control.Exception (SomeException)
import Control.Distributed.Process hiding (bracket, finally, try)
import Control.Distributed.Process.Internal.Types
 ( ProcessExitException(..)
 , unsafeCreateUnencodedMessage
 )
import Control.Distributed.Process.Node
import qualified Control.Distributed.Process.UnsafePrimitives as Unsafe
  ( send
  , nsend
  , nsendRemote
  , usend
  )
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
  )
import Control.Monad (void, unless)
import Control.Monad.Catch(finally, bracket, try)
import Control.Rematch (equalTo)
import Data.Binary
import Data.List (find, sort)
import Data.Maybe (isJust, fromJust, isNothing)
import Data.Typeable
import GHC.Generics hiding (from)
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
    withMonitorRef p = bracket (monitor p) unmonitor

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

  (rc, rs) <- newChan
  agentPid <- mxAgent (MxAgentId "lifecycle-listener-agent") initState [
      (mxSink $ \ev -> do
         st <- mxGetLocal
         let act =
               case ev of
                 (MxSpawned _)       -> mxSetLocal (ev:st)
                 (MxProcessDied _ _) -> mxSetLocal (ev:st)
                 _                   -> return ()
         act >> (liftMX $ sendChan rc ()) >> mxReady),
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

  -- TODO: yes, this is racy, but we're at the mercy of the scheduler here...
  faff 2000000 rs

  _ <- monitor agentPid
  (sp, rp) <- newChan

  pid <- spawnLocal $ expect >>= sendChan sp

  -- By waiting for a monitor notification, we have a
  -- higher probably that the agent has seen the spawn and died events
  monitor pid

  send pid ()
  () <- receiveChan rp

  receiveWait [ match (\(ProcessMonitorNotification _ _ _) -> return ()) ]

  -- TODO: yes, this is racy, but we're at the mercy of the scheduler here...
  faff 2000000 rs

  (replyTo, reply) <- newChan :: Process (SendPort Bool, ReceivePort Bool)
  mxNotify (MxSpawned pid, replyTo)
  mxNotify (MxProcessDied pid DiedNormal, replyTo)

  seenAlive <- receiveChan reply
  seenDead  <- receiveChan reply

  stash result $ seenAlive && seenDead
  kill agentPid "test-complete" >> awaitExit agentPid
  where
    faff delay port = do
      res <- receiveChanTimeout delay port
      unless (isNothing res) $ do
        pause delay
        faff delay port

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

testNSend :: (String -> () -> Process ())
          -> Maybe LocalNode
          -> TestResult Bool
          -> Process ()
testNSend op n r = testMxSend n r $ \p1 sink -> do
  let delay = 5000000
  let label = "testMxSend"
  let isValid = isValidLabel n label

  register label p1
  reg1 <- receiveChanTimeout delay sink
  case reg1 of
    Just (MxRegistered pd lb)
      | pd == p1 && isValid lb -> return ()
    _                          -> die $ "Reg-Failed: " ++ show reg1

  op label ()

  us <- getSelfPid
  sent <- receiveChanTimeout delay sink
  case sent of
    Just (MxSentToName lb by _)
      | by == us && isValid lb -> return True
    _                          -> die $ "Send-Failed: " ++ show sent

  where
    isValidLabel n l1 l2
      | l2 == l2 = True
      | isJust n     = l2 == l1 ++ "@" ++ show (localNodeId $ fromJust n)
      | otherwise    = False

testSend :: (ProcessId -> () -> Process ())
         -> Maybe LocalNode
         -> TestResult Bool
         -> Process ()
testSend op n r = testMxSend n r $ \p1 sink -> do
  -- initiate a send
  op p1 ()

  -- verify the management event
  us <- getSelfPid
  sent <- receiveChanTimeout 5000000 sink
  case sent of
    Just (MxSent pidTo pidFrom _)
      | pidTo == p1 && pidFrom == us -> return True
    _                                -> return False

type SendTest = ProcessId -> ReceivePort MxEvent -> Process Bool

testMxSend :: Maybe LocalNode -> TestResult Bool -> SendTest -> Process ()
testMxSend mNode result test = do
  us <- getSelfPid
  (chan, sink) <- newChan
  agent <- mxAgent (MxAgentId $ agentLabel us) () [
      mxSink $ \ev -> do
        case ev of
          m@(MxSent _ fromPid _)
            | fromPid == us -> liftMX $ sendChan chan m
          m@(MxSentToName _ fromPid _)
            | fromPid == us -> liftMX $ sendChan chan m
          m@(MxRegistered _ name)
            | name == label -> liftMX $ sendChan chan m
          _                 -> return ()
        mxReady
    ]

  (sp, rp) <- newChan
  case mNode of
    Nothing         -> void $ spawnLocal (proc sp)
    Just remoteNode -> void $ liftIO $ forkProcess remoteNode $ proc sp

  p1 <- receiveChan rp
  res <- try (test p1 sink)
  case res of
    Left  (ProcessExitException _ m) -> (liftIO $ putStrLn $ "SomeException-" ++ show m) >> stash result False
    Right tr                         -> stash result tr
  kill agent "bye"
  kill p1 "bye"

  where
    label = "testMxSend"
    agentLabel s = "mx-unsafe-check-agent-" ++ show s
    proc sp' = getSelfPid >>= sendChan sp' >> expect :: Process ()

tests :: TestTransport -> IO [Test]
tests TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  let nid = localNodeId node2
  return [
      testGroup "MxAgents" [
          testCase "EventHandling"
              (delayedAssertion
               "expected True, but events where not as expected"
               node1 True testAgentEventHandling)
        , testCase "InterAgentBroadcast"
              (delayedAssertion
               "expected (), but no broadcast was received"
               node1 () testAgentBroadcast)
        , testCase "AgentMailboxHandling"
              (delayedAssertion
               "expected (Just ()), but no regular (mailbox) input was handled"
               node1 (Just ()) testAgentMailboxHandling)
        , testCase "AgentDualInputHandling"
              (delayedAssertion
               "expected sum = 15, but the result was Nothing"
               node1 (Just 15 :: Maybe Int) testAgentDualInput)
        , testCase "AgentInputPrioritisation"
              (delayedAssertion
               "expected [first, second, third, fourth, fifth], but result diverged"
               node1 (sort ["first", "second",
                            "third", "fourth",
                            "fifth"]) testAgentPrioritisation)
      ]
    , testGroup "MxEvents" [
        testCase "NameRegistrationEvents"
          (delayedAssertion
           "expected registration events to map to the correct ProcessId"
           node1 () testMxRegEvents)
      , testCase "PostDeathNameUnRegistrationEvents"
          (delayedAssertion
           "expected process deaths to result in unregistration events"
           node1 () (testMxRegMon node2))
      , testGroup "SentEvents" [
          testGroup "RemoteTargets" [
            testCase "Unsafe.nsend"
              (delayedAssertion "expected mx events failed"
               node1 True (testNSend Unsafe.nsend $ Just node2))
          , testCase "Unsafe.nsendRemote"
              (delayedAssertion "expected mx events failed"
               node1 True (testNSend (Unsafe.nsendRemote nid) $ Just node2))
          , testCase "Unsafe.send"
              (delayedAssertion "expected mx events failed"
               node1 True (testSend Unsafe.send $ Just node2))
          , testCase "Unsafe.usend"
              (delayedAssertion "expected mx events failed"
               node1 True (testSend Unsafe.usend $ Just node2))
          , testCase "nsend"
               (delayedAssertion "expected mx events failed"
                node1 True (testNSend nsend $ Just node2))
           , testCase "nsendRemote"
               (delayedAssertion "expected mx events failed"
                node1 True (testNSend (nsendRemote nid) $ Just node2))
           , testCase "send"
               (delayedAssertion "expected mx events failed"
                node1 True (testSend send $ Just node2))
           , testCase "usend"
               (delayedAssertion "expected mx events failed"
                node1 True (testSend usend $ Just node2))
           , testCase "forward"
               (delayedAssertion "expected mx events failed"
                node1 True (testSend (\p m -> forward (unsafeCreateUnencodedMessage m) p) $ Just node2))
           , testCase "uforward"
               (delayedAssertion "expected mx events failed"
                node1 True (testSend (\p m -> uforward (unsafeCreateUnencodedMessage m) p) $ Just node2))
          ]
        , testGroup "LocalTargets" [
              testCase "Unsafe.nsend"
              (delayedAssertion "expected mx events failed"
               node1 True (testNSend Unsafe.nsend Nothing))
            , testCase "Unsafe.send"
                (delayedAssertion "expected mx events failed"
                 node1 True (testSend Unsafe.send Nothing))
            , testCase "Unsafe.usend"
                (delayedAssertion "expected mx events failed"
                 node1 True (testSend Unsafe.usend Nothing))
            , testCase "nsend"
                (delayedAssertion "expected mx events failed"
                 node1 True (testNSend nsend Nothing))
            , testCase "send"
                (delayedAssertion "expected mx events failed"
                 node1 True (testSend send Nothing))
            , testCase "usend"
                (delayedAssertion "expected mx events failed"
                 node1 True (testSend usend Nothing))
            , testCase "forward"
                (delayedAssertion "expected mx events failed"
                 node1 True (testSend (\p m -> forward (unsafeCreateUnencodedMessage m) p) Nothing))
            , testCase "uforward"
                (delayedAssertion "expected mx events failed"
                 node1 True (testSend (\p m -> uforward (unsafeCreateUnencodedMessage m) p) Nothing))
            ]
          ]
        ]
      ]
