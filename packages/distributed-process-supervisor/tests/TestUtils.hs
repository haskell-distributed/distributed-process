{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE DeriveGeneric             #-}

module TestUtils
  ( TestResult
    -- ping !
  , Ping(Ping)
  , ping
  , shouldBe
  , shouldMatch
  , shouldContain
  , shouldNotContain
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
  , stash
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
  , putMVar
  )

import Control.Distributed.Process hiding (catch, finally)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Timer
import Control.Distributed.Process.Extras.Internal.Types
import Control.Exception (SomeException)
import qualified Control.Exception as Exception
import Control.Monad (forever)
import Control.Monad.Catch (catch)
import Control.Monad.STM (atomically)
import Control.Rematch hiding (match)
import Control.Rematch.Run
import Test.HUnit (Assertion, assertFailure)
import Test.HUnit.Base (assertBool)
import Test.Framework (Test, defaultMain)
import Control.DeepSeq

import Network.Transport.TCP
import qualified Network.Transport as NT

import Data.Binary
import Data.Typeable
import GHC.Generics

--expect :: a -> Matcher a -> Process ()
--expect a m = liftIO $ Rematch.expect a m

expectThat :: a -> Matcher a -> Process ()
expectThat a matcher = case res of
  MatchSuccess -> return ()
  (MatchFailure msg) -> liftIO $ assertFailure msg
  where res = runMatch matcher a

shouldBe :: a -> Matcher a -> Process ()
shouldBe = expectThat

shouldContain :: (Show a, Eq a) => [a] -> a -> Process ()
shouldContain xs x = expectThat xs $ hasItem (equalTo x)

shouldNotContain :: (Show a, Eq a) => [a] -> a -> Process ()
shouldNotContain xs x = expectThat xs $ isNot (hasItem (equalTo x))

shouldMatch :: a -> Matcher a -> Process ()
shouldMatch = expectThat

shouldExitWith :: (Resolvable a) => a -> DiedReason -> Process ()
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
  Right (transport1, _) <-
    createTransportExposeInternals "127.0.0.1" port ("127.0.0.1",) defaultTCPParameters
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
stopLogger = (flip Exception.throwTo) Exception.ThreadKilled . _tid

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                    "127.0.0.1" "0" ("127.0.0.1",) defaultTCPParameters
  testData <- builder transport
  defaultMain testData

-- | Runs a /test process/ around the supplied @proc@, which is executed
-- whenever the outer process loop receives a 'Go' signal.
runTestProcess :: Process () -> Process ()
runTestProcess proc = do
  ctl <- expect
  case ctl of
    Stop -> return ()
    Go -> proc >> runTestProcess proc
    Report p -> receiveWait [matchAny (\m -> forward m p)] >> runTestProcess proc

-- | Starts a test process on the local node.
startTestProcess :: Process () -> Process ProcessId
startTestProcess proc =
   spawnLocal $ do
     getSelfPid >>= register "test-process"
     runTestProcess proc

-- | Control signals used to manage /test processes/
data TestProcessControl = Stop | Go | Report ProcessId
  deriving (Typeable, Generic)

instance Binary TestProcessControl where

-- | A mutable cell containing a test result.
type TestResult a = MVar a

-- | Stashes a value in our 'TestResult' using @putMVar@
stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

-- | Tell a /test process/ to stop (i.e., 'terminate')
testProcessStop :: ProcessId -> Process ()
testProcessStop pid = send pid Stop

-- | Tell a /test process/ to continue executing
testProcessGo :: ProcessId -> Process ()
testProcessGo pid = send pid Go

-- | A simple @Ping@ signal
data Ping = Ping
  deriving (Typeable, Generic, Eq, Show)

instance Binary Ping where
instance NFData Ping where

ping :: ProcessId -> Process ()
ping pid = send pid Ping


tryRunProcess :: LocalNode -> Process () -> IO ()
tryRunProcess node p = do
  tid <- liftIO myThreadId
  runProcess node $ catch p (\e -> liftIO $ Exception.throwTo tid (e::SomeException))

-- | Tell a /test process/ to send a report (message)
-- back to the calling process
testProcessReport :: ProcessId -> Process ()
testProcessReport pid = do
   self <- getSelfPid
   send pid $ Report self
