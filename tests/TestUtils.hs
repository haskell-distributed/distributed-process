{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestUtils
  ( TestResult
    -- ping !
  , Ping(Ping)
  , ping
  , shouldBe
  , shouldMatch
  , shouldExitWith
  , expectThat
  -- test process utilities
  , TestProcessControl
  , startTestProcess
  , runTestProcess
  , testProcessGo
  , testProcessStop
  , testProcessReport
  , delayedAssertion
  , assertComplete
  , waitForExit
  -- logging
  , Logger()
  , newLogger
  , putLogMsg
  , stopLogger
  -- runners
  , mkNode
  , tryRunProcess
  , testMain
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif
import Control.Concurrent
  ( ThreadId
  , myThreadId
  , forkIO
  )
import Control.Concurrent.STM
  ( TQueue
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , takeMVar
  )

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
import Control.Exception
import Control.Monad (forever)
import Control.Monad.STM (atomically)
import Control.Rematch hiding (match)
import Control.Rematch.Run
import Test.HUnit (Assertion, assertFailure)
import Test.HUnit.Base (assertBool)
import Test.Framework (Test, defaultMain)

import Network.Transport.TCP
import qualified Network.Transport as NT

--expect :: a -> Matcher a -> Process ()
--expect a m = liftIO $ Rematch.expect a m

expectThat :: a -> Matcher a -> Process ()
expectThat a matcher = case res of
  MatchSuccess -> return ()
  (MatchFailure msg) -> liftIO $ assertFailure msg
  where res = runMatch matcher a

shouldBe :: a -> Matcher a -> Process ()
shouldBe = expectThat

shouldMatch :: a -> Matcher a -> Process ()
shouldMatch = expectThat

shouldExitWith :: (Addressable a) => a -> DiedReason -> Process ()
shouldExitWith a r = do
  _ <- resolve a
  d <- receiveWait [ match (\(ProcessMonitorNotification _ _ r') -> return r') ]
  d `shouldBe` equalTo r

waitForExit :: MVar ExitReason
            -> Process (Maybe ExitReason)
waitForExit exitReason = do
    -- we *might* end up blocked here, so ensure the test doesn't jam up!
  self <- getSelfPid
  tref <- killAfter (within 10 Seconds) self "testcast timed out"
  tr <- liftIO $ takeMVar exitReason
  cancelTimer tref
  case tr of
    ExitNormal -> return Nothing
    other      -> return $ Just other

mkNode :: String -> IO LocalNode
mkNode port = do
  Right (transport1, _) <- createTransportExposeInternals
                                    "127.0.0.1" port defaultTCPParameters
  newLocalNode transport1 initRemoteTable

-- | Run the supplied @testProc@ using an @MVar@ to collect and assert
-- against its result. Uses the supplied @note@ if the assertion fails.
delayedAssertion :: (Eq a) => String -> LocalNode -> a ->
                    (TestResult a -> Process ()) -> Assertion
delayedAssertion note localNode expected testProc = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ testProc result
  assertComplete note result expected

-- | Takes the value of @mv@ (using @takeMVar@) and asserts that it matches @a@
assertComplete :: (Eq a) => String -> MVar a -> a -> IO ()
assertComplete msg mv a = do
  b <- takeMVar mv
  assertBool msg (a == b)

-- synchronised logging

data Logger = Logger { _tid :: ThreadId, msgs :: TQueue String }

-- | Create a new Logger.
-- Logger uses a 'TQueue' to receive and process messages on a worker thread.
newLogger :: IO Logger
newLogger = do
  tid <- liftIO $ myThreadId
  q <- liftIO $ newTQueueIO
  _ <- forkIO $ logger q
  return $ Logger tid q
  where logger q' = forever $ do
        msg <- atomically $ readTQueue q'
        putStrLn msg

-- | Send a message to the Logger
putLogMsg :: Logger -> String -> Process ()
putLogMsg logger msg = liftIO $ atomically $ writeTQueue (msgs logger) msg

-- | Stop the worker thread for the given Logger
stopLogger :: Logger -> IO ()
stopLogger = (flip throwTo) ThreadKilled . _tid

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                    "127.0.0.1" "8080" defaultTCPParameters
  testData <- builder transport
  defaultMain testData
