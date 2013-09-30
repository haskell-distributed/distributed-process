module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
  ( newEmptyMVar
  , tryPutMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Management
  ( MxEvent(..)
  , MxAgentId(..)
  , mxAgent
  , mxSink
  , mxReady
  , mxLift
  , mxGetLocal
  , mxSetLocal
  , mxNotify
  )
import Control.Distributed.Process.Node
  ( LocalNode
  )
import Data.List (find)
import Data.Maybe (isJust)
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

testAgentEventHandling :: TestResult Bool -> Process ()
testAgentEventHandling result = do
  let initState = [] :: [MxEvent]
  agentPid  <- mxAgent (MxAgentId "lifecycle-listener-agent") initState [
      (mxSink $ \ev -> do
         st <- mxGetLocal
         let act = case ev of
                     (MxSpawned _)       -> mxSetLocal (ev:st)
                     (MxProcessDied _ _) -> mxSetLocal (ev:st)
                     _         -> return ()
         act >> mxReady),
      (mxSink $ \(ev, sp :: SendPort Bool) -> do
          st <- mxGetLocal
          let found = case ev of
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
          mxLift $ sendChan sp found
          liftIO $ putStrLn $ "replied to " ++ (show sp)
          mxReady)
    ]

  mref <- monitor agentPid
  (sp, rp) <- newChan
  pid <- spawnLocal $ sendChan sp ()
  () <- receiveChan rp

  (replyTo, reply) <- newChan :: Process (SendPort Bool, ReceivePort Bool)
  mxNotify (MxSpawned pid, replyTo)
  mxNotify (MxProcessDied pid DiedNormal, replyTo)

  seenAlive <- receiveChan reply
  seenDead  <- receiveChan reply

  stash result $ seenAlive && seenDead

  kill agentPid "finished"
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              ((\_ -> return ()))
    ]

tests :: LocalNode -> IO [Test]
tests node1 = do
  return [
    testGroup "Basic Agent Handling" [
        testCase "testAgentEventHandling"
            (delayedAssertion
             "expected "
             node1 True testAgentEventHandling)
    ] ]

statsTests :: NT.Transport -> IO [Test]
statsTests _ = do
  mkNode "8080" >>= tests >>= return

main :: IO ()
main = do
  testMain $ statsTests
  threadDelay 100000

