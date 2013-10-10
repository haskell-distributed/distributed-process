{-# LANGUAGE DeriveGeneric #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Management
  ( MxEvent(..)
  , MxAgentId(..)
  , mxAgent
  , mxSink
  , mxReady
  , liftMX
  , mxGetLocal
  , mxSetLocal
  , mxNotify
  , mxBroadcast
  , mxGetId
  , mxGet
  , mxSet
  , mxClear
  , mxPurgeTable
  , mxDropTable
  )
import Control.Distributed.Process.Node
  ( LocalNode
  )
import Data.Binary
import Data.List (find)
import Data.Maybe (isJust)
import Data.Typeable
import GHC.Generics
import qualified Network.Transport as NT
#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, log)
#endif

import Test.Framework
  ( Test
  , testGroup
  )
import Test.Framework.Providers.HUnit (testCase)
import TestUtils

data Publish = Publish
  deriving (Typeable, Generic, Eq)

instance Binary Publish where

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
  -- once the publisher has seen our message, it will broadcast the Publish
  stash result =<< receiveChanTimeout 1000000 resultRP

  kill publisher "finished"
  kill consumer "finished"

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

testAgentPublication :: TestResult (Maybe Publish) -> Process ()
testAgentPublication result = do
  (syncChan, rp) <- newChan
  let ourId = MxAgentId "publication-agent"
  agentPid <- mxAgent ourId () [
      mxSink $ \() -> do
         selfId <- mxGetId
         liftMX $ mxSet selfId "publish" Publish >> sendChan syncChan ()
         mxReady
    ]

  mxNotify ()
  () <- receiveChan rp

  stash result =<< mxGet ourId "publish"

  mref <- monitor agentPid
  kill agentPid "finished"
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              ((\_ -> return ()))
    ]

testAgentTableClear :: Int -> TestResult (Maybe Int, Maybe Int) -> Process ()
testAgentTableClear val result =
  let tId  = (MxAgentId "agent-1")
      tKey = "key-1" in do
    mxSet tId tKey val
    get1 <- mxGet tId tKey
    mxClear tId tKey
    get2 <- mxGet tId tKey
    stash result (get1, get2)

testAgentTablePurge :: TestResult (Maybe Int) -> Process ()
testAgentTablePurge result =
  let tId  = MxAgentId "agent-2"
      tKey = "key-2" in do
    mxSet tId tKey (12345 :: Int)
    mxPurgeTable tId
    stash result =<< mxGet tId tKey

testAgentTableDelete :: Int
                     -> TestResult (Maybe Int, Maybe Int, Maybe Int)
                     -> Process ()
testAgentTableDelete val result =
  let tId  = (MxAgentId "agent-3")
      tKey = "key-3" in do
    mxSet tId tKey val
    get1 <- mxGet tId tKey
    mxDropTable tId
    get2 <- mxGet tId tKey
    mxSet tId tKey val
    get3 <- mxGet tId tKey
    stash result (get1, get2, get3)

tests :: LocalNode -> IO [Test]
tests node1 = do
  return [
    testGroup "Mx Agents" [
        testCase "Event Handling"
            (delayedAssertion
             "expected True, but events where not as expected"
             node1 True testAgentEventHandling)
      , testCase "Inter-Agent Broadcast"
            (delayedAssertion
             "expected (Just ()), but no broadcast was received"
             node1 (Just ()) testAgentBroadcast)
    ],
    testGroup "Mx Global Properties" [
        testCase "Global Property Publication"
            (delayedAssertion
             "expected (Just Publish), but no table entry was found"
             node1 (Just Publish) testAgentPublication)
      , testCase "Clearing Global Properties"
            (delayedAssertion
             "expected (Just 1024, Nothing): invalid table entry found!"
             node1 (Just 1024, Nothing) (testAgentTableClear 1024))
      , testCase "Purging Global Tables"
            (delayedAssertion
             "expected Nothing, but a table entry was found"
             node1 Nothing testAgentTablePurge)
      , testCase "Deleting and (Re)Creating Global Tables"
            (delayedAssertion
             "expected (Just 15, Nothing, Just 15): invalid table entry found!"
             node1 (Just 15, Nothing, Just 15) (testAgentTableDelete 15))
      ]]

statsTests :: NT.Transport -> IO [Test]
statsTests _ = do
  mkNode "8080" >>= tests >>= return

main :: IO ()
main = do
  testMain $ statsTests
  threadDelay 100000

