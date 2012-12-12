{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestUtils
  ( TestResult
  , noop
  , stash
  -- ping !
  , Ping(Ping)
  , ping
  -- test process utilities
  , TestProcessControl
  , startTestProcess
  , runTestProcess
  , testProcessGo
  , testProcessStop
  , testProcessReport
  , delayedAssertion
  , assertComplete
  ) where

import Prelude hiding (catch)
import Data.Binary
import Data.Typeable (Typeable)
import Data.DeriveTH
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()

import Control.Monad (forever)

import Test.HUnit (Assertion)
import Test.HUnit.Base (assertBool)

-- | A mutable cell containing a test result.
type TestResult a = MVar a

-- | A simple @Ping@ signal
data Ping = Ping
    deriving (Typeable, Eq, Show)
$(derive makeBinary ''Ping)

ping :: ProcessId -> Process ()
ping pid = send pid Ping

-- | Control signals used to manage /test processes/
data TestProcessControl = Stop | Go | Report ProcessId
    deriving (Typeable)
$(derive makeBinary ''TestProcessControl)

-- | Starts a test process on the local node.
startTestProcess :: Process () -> Process ProcessId
startTestProcess proc = spawnLocal $ runTestProcess proc

-- | Runs a /test process/ around the supplied @proc@, which is executed
-- whenever the outer process loop receives a 'Go' signal.
runTestProcess :: Process () -> Process ()
runTestProcess proc = forever $ do
  ctl <- expect
  case ctl of
    Stop     -> terminate
    Go       -> proc
    Report p -> receiveWait [matchAny (\m -> forward m p)] >> return ()

-- | Tell a /test process/ to continue executing 
testProcessGo :: ProcessId -> Process ()
testProcessGo pid = (say $ (show pid) ++ " go!") >> send pid Go

-- | Tell a /test process/ to stop (i.e., 'terminate')
testProcessStop :: ProcessId -> Process ()
testProcessStop pid = (say $ (show pid) ++ " stop!") >> send pid Stop

-- | Tell a /test process/ to send a report (message)
-- back to the calling process
testProcessReport :: ProcessId -> Process ()
testProcessReport pid = do
  self <- getSelfPid
  send pid $ Report self
          
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

-- | Does exactly what it says on the tin, doing so in the @Process@ monad.
noop :: Process ()
noop = return ()

-- | Stashes a value in our 'TestResult' using @putMVar@
stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

