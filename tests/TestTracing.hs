{-# LANGUAGE DeriveDataTypeable        #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
module Main where

import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Debug
import Control.Distributed.Process.Node
  ( forkProcess
  , newLocalNode
  , initRemoteTable
  , closeLocalNode
  , LocalNode)
import Control.Exception as Ex (catch)
import Data.Binary()
import Data.Typeable()
import Network.Transport.TCP
import Prelude hiding (catch, log)
import Test.Framework
  ( Test
  , defaultMain
  , testGroup
  )
import Test.HUnit (Assertion)
import Test.HUnit.Base (assertBool)
import Test.Framework.Providers.HUnit (testCase)

import System.Environment (getEnv)
import System.Posix.Env
  ( setEnv
  )

-- these utilities have been cribbed from distributed-process-platform
-- we should really find a way to share them...

-- | A mutable cell containing a test result.
type TestResult a = MVar a

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

stash :: TestResult a -> a -> Process ()
stash mvar x = liftIO $ putMVar mvar x

------

testSpawnTracing :: TestResult Bool -> Process ()
testSpawnTracing result = do
  setTraceFlags defaultTraceFlags {
      traceSpawned = (Just TraceAll)
    , traceDied    = (Just TraceAll)
    }

  evSpawned <- liftIO $ newEmptyMVar
  evDied <- liftIO $ newEmptyMVar
  startTracer $ \ev -> do
    case ev of
      (TraceEvSpawned p) -> liftIO $ putMVar evSpawned p
      (TraceEvDied p r)  -> liftIO $ putMVar evDied (p, r)
      _ -> return ()

  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    sendChan sp ()
  () <- receiveChan rp

  tracedAlive <- liftIO $ takeMVar evSpawned
  (tracedDead, tracedReason) <- liftIO $ takeMVar evDied

  stopTracer
  setTraceFlags defaultTraceFlags
  stash result (tracedAlive  == pid &&
                tracedDead   == pid &&
                tracedReason == DiedNormal)

testTraceRecvExplicitPid :: TestResult Bool -> Process ()
testTraceRecvExplicitPid result = do
  say "testTraceRecvExplicitPid"
  pid <- spawnLocal $ do
    self <- getSelfPid
    expect >>= (flip sendChan) self
  withFlags defaultTraceFlags {
    traceRecv = traceOnly [pid]
    } $ do
    withTracer
      (\ev ->
        case ev of
          (TraceEvReceived pid' _) -> stash result (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res <- liftIO $ takeMVar result
        stash result (res && (p == pid))
  say "Explicit done!!!"
  return ()

testTraceRecvNamedPid :: TestResult Bool -> Process ()
testTraceRecvNamedPid result = do
  say "testTraceRecvNamedPid"
  pid <- spawnLocal $ do
    self <- getSelfPid
    register "foobar" self
    expect >>= (flip sendChan) self
  withFlags defaultTraceFlags {
    traceRecv = traceOnly ["foobar"]
    } $ do
    withTracer
      (\ev ->
        case ev of
          (TraceEvReceived pid' _) -> stash result (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res <- liftIO $ takeMVar result
        stash result (res && (p == pid))
  return ()

data TraceWhat = User | Die | Rec
  deriving (Show)

testTraceLayering :: TestResult () -> Process ()
testTraceLayering result = do
  pid <- spawnLocal $ do
    getSelfPid >>= register "foobar"
    say "registered - waiting for 'hello'"
    "hello" <- expect
    say "received 'hello' - waiting for () go"
    p <- expect
    say "pid received - sending trace msg"
    traceMessage ("traceMsg", 123 :: Int)
    say "sending reply"
    send p ()
    () <- expect
    return ()
  withFlags defaultTraceFlags {
      traceDied    = traceOnly ["foobar"]
    , traceRecv    = traceOnly [pid]
    } $ doTest pid result
  return ()
  where
    doTest :: ProcessId -> MVar () -> Process ()
    doTest pid result' = do
      go Die $ do
        go Rec $ do
          say "sending 'hello'"
          send pid "hello"
          go User $ do
            getSelfPid >>= send pid
            () <- expect
            say "received reply, returning to rec block"
            return ()
      liftIO $ putMVar result' ()

    go :: TraceWhat -> Process () -> Process ()
    go what proc = do {
        say ("tracing " ++ (show what))
      ; mv <- liftIO $ newEmptyMVar
      ; r <- (withTracer
          (\ev ->
            case (matchTest what ev) of
              True  -> do
                say ("matched " ++ (show ev))
                liftIO $ putMVar mv ()
              False -> say ("ignoring " ++ (show ev))) $ do
            say ("in block for " ++ (show what))
            proc)
      ; case r of
          Left  e -> say "whoops"
          Right _ -> say "ok!" >> (liftIO $ takeMVar mv)
      }

    matchTest :: TraceWhat -> TraceEvent -> Bool
    matchTest User  (TraceEvUser     _)   = True
    matchTest Die   (TraceEvDied     _ _) = True
    matchTest Rec   (TraceEvReceived _ _) = True
    matchTest _     _                     = False

tests :: LocalNode -> IO [Test]
tests node1 = do
  enabled <- checkTraceEnabled
  case enabled of
    True ->
      return [
        testGroup "Process Info" [
           testCase "Test Spawn Tracing"
             (delayedAssertion
              "expected dead process-info to be ProcessInfoNone"
              node1 True testSpawnTracing)
         , testCase "Test Recv Tracing (Explicit Pid)"
             (delayedAssertion
              "expected a recv trace for the supplied pid"
              node1 True testTraceRecvExplicitPid)
         , testCase "Test Recv Tracing (Named Pid)"
             (delayedAssertion
              "expected a recv trace for the process registered as 'foobar'"
              node1 True testTraceRecvNamedPid)
         , testCase "Test Trace Layering"
             (delayedAssertion
              "expected blah"
              node1 () testTraceLayering)
         ] ]
    False ->
      return []

checkTraceEnabled :: IO Bool
checkTraceEnabled =
  Ex.catch (getEnv "DISTRIBUTED_PROCESS_TRACE_ENABLED" >> return True)
           (\(_ :: IOError) -> return False)


mkNode :: String -> IO LocalNode
mkNode port = do
  Right (transport1, _) <- createTransportExposeInternals
                                    "127.0.0.1" port defaultTCPParameters
  newLocalNode transport1 initRemoteTable

main :: IO ()
main = do
  setEnv "DISTRIBUTED_PROCESS_TRACE_ENABLED" "true" True
  node1 <- mkNode "8081"
  testData <- tests node1
  defaultMain testData
  closeLocalNode node1
  return ()

