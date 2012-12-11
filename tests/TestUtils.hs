{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module TestUtils
  ( TestResult
  , TestProcessControl
  , Ping(Ping)
  , startTestProcess
  , delayedAssertion
  , assertComplete
  , noop
  , stash
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

type TestResult a = MVar a

data Ping = Ping
    deriving (Typeable)
$(derive makeBinary ''Ping)

data TestProcessControl = Stop | Go | Report ProcessId
    deriving (Typeable)
$(derive makeBinary ''TestProcessControl)

startTestProcess :: Process () -> Process ProcessId
startTestProcess proc = spawnLocal $ testProcess proc

testProcess :: Process () -> Process ()
testProcess proc = forever $ do
  ctl <- expect
  case ctl of
    Stop     -> terminate
    Go       -> proc
    Report p -> acquireAndRespond p
  where acquireAndRespond :: ProcessId -> Process ()
        acquireAndRespond p = do
          _ <- receiveWait [
              matchAny (\m -> forward m p)
            ]
          return ()
          
delayedAssertion :: (Eq a) => String -> LocalNode -> a ->
                    (TestResult a -> Process ()) -> Assertion
delayedAssertion note localNode expected testProc = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ testProc result
  assertComplete note result expected

assertComplete :: (Eq a) => String -> MVar a -> a -> IO ()
assertComplete msg mv a = do
    b <- takeMVar mv
    assertBool msg (a == b)

noop :: Process ()
noop = return ()

stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

