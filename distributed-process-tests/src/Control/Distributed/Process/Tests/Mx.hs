{-# LANGUAGE DeriveGeneric    #-}
{-# LANGUAGE ParallelListComp #-}

module Control.Distributed.Process.Tests.Mx (tests) where

import Control.Distributed.Process.Tests.Internal.Utils
import Network.Transport.Test (TestTransport(..))
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
  , sendChan
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
import Data.List (find, sort, intercalate)
import Data.Maybe (isJust, fromJust, isNothing, fromMaybe, catMaybes)
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

testAgentBroadcast :: TestResult (Maybe ()) -> Process ()
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
  stash result =<< receiveChanTimeout 10000000 resultRP

  kill publisher "finished"
  kill consumer  "finished"

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

  mRef <- monitor s

  mxNotify          (1 :: Int)
  nsend "sum-agent" (3 :: Int)
  mxNotify          (2 :: Int)
  nsend "sum-agent" (4 :: Int)
  mxNotify          (5 :: Int)

  stash result =<< receiveChanTimeout 10000000 rp
  died <- receiveTimeout 10000000 [
      matchIf (\(ProcessMonitorNotification r _ _) -> r == mRef) (const $ return True)
    ]
  died `shouldBe` equalTo (Just True)

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
                   mxUpdateLocal (s:)
                   st <- mxGetLocal
                   case length st of
                     n | n == 5 -> do liftMX $ sendChan sp (sort st)
                                      mxDeactivate "finished"
                     _          -> mxReceive  -- go to the mailbox
                   )
    ]

  nsend name "second"
  mxNotify "third"
  mxNotify "fourth"
  nsend name "fifth"

  stash result . fromMaybe [] =<< receiveChanTimeout 10000000 rp
  awaitExit s

testAgentMailboxHandling :: TestResult (Maybe ()) -> Process ()
testAgentMailboxHandling result = do
  (sp, rp) <- newChan
  agent <- mxAgent (MxAgentId "mailbox-agent") () [
      mxSink $ \() -> (liftMX $ sendChan sp ()) >> mxReady
    ]

  nsend "mailbox-agent" ()

  stash result =<< receiveChanTimeout 1000000 rp
  kill agent "finished"

testAgentEventHandling :: TestResult Bool -> Process ()
testAgentEventHandling result = do
  us <- getSelfPid
  -- because this test is a bit racy, let's ensure it can't run indefinitely
  timer <- spawnLocal $ do
    pause (1000000 * 60 * 5)
    -- okay we've waited 5 mins, let's kill the test off if it's stuck...
    stash result False
    kill us "Test Timed Out"

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

  (sp, rp) <- newChan :: Process (SendPort (), ReceivePort ())

  pid <- spawnLocal $ expect >>= sendChan sp

  -- By waiting for a monitor notification, we have a
  -- higher probably that the agent has seen the spawn and died events
  monitor pid

  send pid ()
  rct <- receiveChanTimeout 10000000 rp
  unless (isJust rct) $ die "No response on channel"

  pmn <- receiveTimeout 2000000 [ match (\ProcessMonitorNotification{} -> return ()) ]
  unless (isJust pmn) $ die "No monitor notification arrived"

  -- TODO: yes, this is racy, but we're at the mercy of the scheduler here...
  faff 2000000 rs

  (replyTo, reply) <- newChan :: Process (SendPort Bool, ReceivePort Bool)
  mxNotify (MxSpawned pid, replyTo)
  mxNotify (MxProcessDied pid DiedNormal, replyTo)

  seenAlive <- receiveChanTimeout 10000000 reply
  seenDead  <- receiveChanTimeout 10000000 reply

  stash result $ foldr (&&) True $ catMaybes [seenAlive, seenDead]
  kill timer "test-complete"
  kill agentPid "test-complete"
  where
    faff delay port = do
      res <- receiveChanTimeout delay port
      unless (isNothing res) $ pause delay

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

    kill agent "test-complete"

ensure :: Process () -> Process () -> Process ()
ensure = flip finally

testNSend :: (String -> () -> Process ())
          -> Maybe LocalNode
          -> Process ()
testNSend op n = do
  us <- getSelfPid
  let delay = 5000000
  let label = "testMxSend" ++ (show us)
  let isValid = isValidLabel n label

  testMxSend n label $ \p1 sink -> do
    register label p1
    reg1 <- receiveChanTimeout delay sink
    case reg1 of
      Just (MxRegistered pd lb)
        | pd == p1 && isValid lb -> return ()
      _                          -> die $ "Reg-Failed: " ++ show reg1

    op label ()

    sent <- receiveChanTimeout delay sink
    case sent of
      Just (MxSentToName lb by _)
        | by == us && isValid lb -> return True
      _                          -> die $ "Send-Failed: " ++ show sent

  where
    isValidLabel nd l1 l2
      | l2 == l2 = True
      | isJust nd     = l2 == l1 ++ "@" ++ show (localNodeId $ fromJust nd)
      | otherwise    = False

testSend :: (ProcessId -> () -> Process ())
         -> Maybe LocalNode
         -> Process ()
testSend op n = do
  us <- getSelfPid
  let label = "testMxSend" ++ (show us)
  testMxSend n label $ \p1 sink -> do
    -- initiate a send
    op p1 ()

    -- verify the management event
    sent <- receiveChanTimeout 5000000 sink
    case sent of
      Just (MxSent pidTo pidFrom _)
        | pidTo == p1 && pidFrom == us -> return True
      _                                -> return False

testChan :: (SendPort () -> () -> Process ())
         -> Maybe LocalNode
         -> Process ()
testChan op n = testMxSend n "" $ \p1 sink -> do

  us <- getSelfPid
  send p1 us

  cleared <- receiveChanTimeout 2000000 sink
  case cleared of
    Just (MxSent pidTo pidFrom _)
      | pidTo == p1 && pidFrom == us -> return ()
    _                                -> die "Received uncleared Mx Event"

  chan <- receiveTimeout 5000000 [ match return ]
  let ch' = fromMaybe (error "No reply chan received") chan

  -- initiate a send
  op ch' ()

  -- verify the management event
  sent <- receiveChanTimeout 5000000 sink
  case sent of
    Just (MxSentToPort sId spId _)
      | sId == us && spId == sendPortId ch' -> return True
    _                                       -> return False

type SendTest = ProcessId -> ReceivePort MxEvent -> Process Bool

testMxSend :: Maybe LocalNode -> String -> SendTest -> Process ()
testMxSend mNode label test = do
  us <- getSelfPid
  (sp, rp) <- newChan
  (chan, sink) <- newChan
  agent <- mxAgent (MxAgentId $ agentLabel us) () [
      mxSink $ \ev -> do
        case ev of
          m@(MxSentToPort _ cid _)
            | cid /= sendPortId chan
              && cid /= sendPortId sp -> liftMX $ sendChan chan m
          m@(MxSent _ fromPid _)
            | fromPid == us -> liftMX $ sendChan chan m
          m@(MxSentToName _ fromPid _)
            | fromPid == us -> liftMX $ sendChan chan m
          m@(MxRegistered _ name)
            | name == label -> liftMX $ sendChan chan m
          _                 -> return ()
        mxReady
    ]

  case mNode of
    Nothing         -> void $ spawnLocal (proc sp)
    Just remoteNode -> void $ liftIO $ forkProcess remoteNode $ proc sp

  p1 <- receiveChanTimeout 2000000 rp
  unless (isJust p1) $ die "Timed out waiting for ProcessId"
  res <- try $ test (fromJust p1) sink

  kill agent "bye"
  kill (fromJust p1) "bye"

  case res of
    Left  (ProcessExitException _ m) -> (liftIO $ putStrLn $ "SomeException-" ++ show m) >> die m
    Right tr                         -> tr `shouldBe` equalTo True


  where
    agentLabel s = "mx-unsafe-check-agent-" ++ show s
    proc sp' = getSelfPid >>= sendChan sp' >> go Nothing

    go :: Maybe (ReceivePort ()) -> Process ()
    go Nothing = receiveTimeout 5000000 [ match replyChannel ] >>= go
    go c@(Just c') = receiveWait [ matchChan c' return ] >> go c

    replyChannel p' = do
      (s, r) <- newChan
      send p' s
      return r

tests :: TestTransport -> IO [Test]
tests TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  return [
      testGroup "MxAgents" [
          testCase "EventHandling"
              (delayedAssertion
               "expected True, but events where not as expected"
               node1 True testAgentEventHandling)
        , testCase "InterAgentBroadcast"
              (delayedAssertion
               "expected (), but no broadcast was received"
               node1 (Just ()) testAgentBroadcast)
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
      , testGroup "SendEvents" $ buildTestCases node1 node2
      ]
    ]
  where
    buildTestCases n1 n2 = let nid = localNodeId n2 in build n1 n2 [
              ("NSend", [
                  ("nsend",              testNSend nsend)
                , ("Unsafe.nsend",       testNSend Unsafe.nsend)
                , ("nsendRemote",        testNSend (nsendRemote nid))
                , ("Unsafe.nsendRemote", testNSend (Unsafe.nsendRemote nid))
                ])
            , ("Send", [
                  ("send",            testSend send)
                , ("Unsafe.send",     testSend Unsafe.send)
                , ("usend",           testSend usend)
                , ("Unsafe.usend",    testSend Unsafe.usend)
                , ("sendChan",        testChan sendChan)
                , ("Unsafe.sendChan", testChan Unsafe.sendChan)
                ])
            , ("Forward", [
                  ("forward",  testSend (\p m -> forward (unsafeCreateUnencodedMessage m) p))
                , ("uforward", testSend (\p m -> uforward (unsafeCreateUnencodedMessage m) p))
                ])
            ]

    build :: LocalNode
          -> LocalNode
          -> [(String, [(String, (Maybe LocalNode -> Process ()))])]
          -> [Test]
    build n ln specs =
      [ testGroup (intercalate "-" [groupName, caseSuffix]) [
             testCase (intercalate "-" [caseName, caseSuffix])
               (runProcess n (caseImpl caseNode))
             | (caseName, caseImpl) <- groupCases
           ]
         | (groupName, groupCases) <- specs
         , (caseSuffix, caseNode) <- [("RemotePid", Just ln), ("LocalPid", Nothing)]
      ]
