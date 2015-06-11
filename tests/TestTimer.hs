module Main where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif
import Control.Monad (forever)
import Control.Concurrent.MVar
  ( newEmptyMVar
  , putMVar
  , takeMVar
  , withMVar
  )
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP()
import Control.DeepSeq (NFData)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Timer
import Control.Distributed.Process.Tests.Internal.Utils

import Test.Framework (Test, testGroup, defaultMain)
import Test.Framework.Providers.HUnit (testCase)
import Network.Transport.TCP
import qualified Network.Transport as NT

import GHC.Generics

-- orphan instance
instance NFData Ping where

testSendAfter :: TestResult Bool -> Process ()
testSendAfter result =
  let delay = seconds 1 in do
  sleep $ seconds 10
  pid <- getSelfPid
  _ <- sendAfter delay pid Ping
  hdInbox <- receiveTimeout (asTimeout (seconds 2)) [
                      match (\m@(Ping) -> return m)
                    ]
  case hdInbox of
      Just Ping -> stash result True
      Nothing   -> stash result False

testRunAfter :: TestResult Bool -> Process ()
testRunAfter result =
  let delay = seconds 2 in do

  parentPid <- getSelfPid
  _ <- spawnLocal $ do
    _ <- runAfter delay $ send parentPid Ping
    return ()

  msg <- expectTimeout ((asTimeout delay) * 4)
  case msg of
      Just Ping -> stash result True
      Nothing   -> stash result False
  return ()

testCancelTimer :: TestResult Bool -> Process ()
testCancelTimer result = do
  let delay = milliSeconds 50
  pid <- periodically delay noop
  ref <- monitor pid

  sleep $ seconds 1
  cancelTimer pid

  _ <- receiveWait [
          match (\(ProcessMonitorNotification ref' pid' _) ->
                  stash result $ ref == ref' && pid == pid')
        ]

  return ()

testPeriodicSend :: TestResult Bool -> Process ()
testPeriodicSend result = do
  let delay = milliSeconds 100
  self <- getSelfPid
  ref <- ticker delay self
  listener 0 ref
  liftIO $ putMVar result True
  where listener :: Int -> TimerRef -> Process ()
        listener n tRef | n > 10    = cancelTimer tRef
                        | otherwise = waitOne >> listener (n + 1) tRef
        -- get a single tick, blocking indefinitely
        waitOne :: Process ()
        waitOne = do
            Tick <- expect
            return ()

testTimerReset :: TestResult Int -> Process ()
testTimerReset result = do
  let delay = seconds 10
  counter <- liftIO $ newEmptyMVar

  listenerPid <- spawnLocal $ do
      stash counter 0
      -- we continually listen for 'ticks' and increment counter for each
      forever $ do
        Tick <- expect
        liftIO $ withMVar counter (\n -> (return (n + 1)))

  -- this ticker will 'fire' every 10 seconds
  ref <- ticker delay listenerPid

  sleep $ seconds 2
  resetTimer ref

  -- at this point, the timer should be back to roughly a 5 second count down
  -- so our few remaining cycles no ticks ought to make it to the listener
  -- therefore we kill off the timer and the listener now and take the count
  cancelTimer ref
  kill listenerPid "stop!"

  -- how many 'ticks' did the listener observer? (hopefully none!)
  count <- liftIO $ takeMVar counter
  liftIO $ putMVar result count

testTimerFlush :: TestResult Bool -> Process ()
testTimerFlush result = do
  let delay = seconds 1
  self <- getSelfPid
  ref  <- ticker delay self

  -- sleep so we *should* have a message in our 'mailbox'
  sleep $ milliSeconds 2

  -- flush it out if it's there
  flushTimer ref Tick (Delay $ seconds 3)

  m <- expectTimeout 10
  case m of
      Nothing   -> stash result True
      Just Tick -> stash result False

testSleep :: TestResult Bool -> Process ()
testSleep r = do
  sleep $ seconds 20
  stash r True

--------------------------------------------------------------------------------
-- Utilities and Plumbing                                                     --
--------------------------------------------------------------------------------

tests :: LocalNode  -> [Test]
tests localNode = [
    testGroup "Timer Tests" [
        testCase "testSendAfter"
                 (delayedAssertion
                  "expected Ping within 1 second"
                  localNode True testSendAfter)
      , testCase "testRunAfter"
                 (delayedAssertion
                  "expecting run (which pings parent) within 2 seconds"
                  localNode True testRunAfter)
      , testCase "testCancelTimer"
                 (delayedAssertion
                  "expected cancelTimer to exit the timer process normally"
                  localNode True testCancelTimer)
      , testCase "testPeriodicSend"
                 (delayedAssertion
                  "expected ten Ticks to have been sent before exiting"
                  localNode True testPeriodicSend)
      , testCase "testTimerReset"
                 (delayedAssertion
                  "expected no Ticks to have been sent before resetting"
                  localNode 0 testTimerReset)
      , testCase "testTimerFlush"
                 (delayedAssertion
                  "expected all Ticks to have been flushed"
                  localNode True testTimerFlush)
      , testCase "testSleep"
                 (delayedAssertion
                  "why am I not seeing a delay!?"
                  localNode True testTimerFlush)
      ]
  ]

timerTests :: NT.Transport -> IO [Test]
timerTests transport = do
  localNode <- newLocalNode transport initRemoteTable
  let testData = tests localNode
  return testData

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                     "127.0.0.1" "0" defaultTCPParameters
  testData <- builder transport
  defaultMain testData

main :: IO ()
main = testMain $ timerTests
