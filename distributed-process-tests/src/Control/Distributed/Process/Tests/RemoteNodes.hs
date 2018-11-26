{-# LANGUAGE StaticPointers #-}

module Control.Distributed.Process.Tests.RemoteNodes (tests, remoteTable) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.Framework (defaultMainWithArgs)
import System.Environment (getArgs)
import System.IO
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Tests.Internal.Utils (shouldBe, pause)
import Control.Distributed.Static (registerStatic, staticClosure, staticLabel)
import Control.Monad (void)
import Data.Rank1Dynamic (toDynamic)
import Data.Maybe (isNothing, isJust)
import Test.HUnit (Assertion, assertBool)
import Test.Framework (Test)
import Test.Framework.Providers.HUnit (testCase)
-- import Control.Rematch hiding (match, isNothing, isJust)
-- import Control.Rematch.Run (Match(..))

--------------------------------------------------------------------------------
-- The tests proper                                                           --
--------------------------------------------------------------------------------

awaitsRegistration :: Process ()
awaitsRegistration = do
  self <- getSelfPid
  nid <- expect :: Process NodeId
  runUntilRegistered nid self
  say $ regName ++ " registered to " ++ show self
  expect :: Process ()
  where
    runUntilRegistered nid us = do
      whereisRemoteAsync nid regName
      receiveWait [
          matchIf (\(WhereIsReply n (Just p)) -> n == regName && p == us)
                  (const $ return ())
        ]

regName :: String
regName = "testRegisterRemote"

awaitsRegClosure :: Closure (Process ())
awaitsRegClosure = staticClosure (staticLabel "$awaitsRegistration")

remoteTable :: RemoteTable -> RemoteTable
remoteTable =
  registerStatic "$awaitsRegistration" $ toDynamic awaitsRegistration

testRegistryMonitoring :: LocalNode -> NodeId -> Assertion
testRegistryMonitoring node nid =
  runProcess node $ do
    pid <- spawn nid awaitsRegClosure
    liftIO $ putStrLn $ "spawned " ++ show pid
    register regName pid
    res <- whereis regName
    liftIO $ assertBool ("expected Just pid but was " ++ show res) $ res == Just pid

    send pid nid

    -- This delay isn't essential!
    -- The test case passes perfectly fine without it (feel free to comment out
    -- and see), however waiting a few seconds here, makes it much more likely
    -- that in delayUntilMaybeUnregistered we will hit the match case right
    -- away, and thus not be subjected to a 20 second delay. The value of 4
    -- seconds appears to work optimally on osx and across several linux distros
    -- running in virtual machines (which is essentially what we do in CI)
    void $ receiveTimeout 4000000 [ matchAny return ]

    -- this message should cause the remote process to exit normally
    send pid ()

    -- This delay doesn't serve much purpose in the happy path, however if some
    -- future patch breaks the cooperative behaviour of node controllers viz
    -- remote process registration and notification taking place via ncEffectDied,
    -- there would be the possibility of a race in the test case should we attempt
    -- to evaluate `whereis regName` on node2 right away. In case the name is still
    -- erroneously registered, observing the 20 second delay (or lack of), could at
    -- least give a hint that something is wrong, and we give up our time slice
    -- so that there's a higher change the registrations have been cleaned up
    -- in either case.
    delayUntilMaybeUnregistered nid pid

    res <- whereis regName
    case res of
      Nothing  -> return ()
      Just pid -> liftIO $ assertBool ("expected Nothing, but got " ++ show pid) False

  where
    delayUntilMaybeUnregistered nid p = do
      whereisRemoteAsync nid regName
      receiveTimeout 20000000 {- 20 sec delay -} [
          matchIf (\(WhereIsReply n p) -> n == regName && isNothing p)
                  (const $ return ())
        ]
      return ()

tests :: LocalNode -> NodeId -> IO [Test]
tests node nid = return [
      testCase "RegistryMonitoring" (testRegistryMonitoring node nid)
    ]
