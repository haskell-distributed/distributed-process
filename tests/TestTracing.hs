{-# LANGUAGE DeriveDataTypeable        #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
module Main where

import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , newMVar
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

delayedAssertion :: (Eq a)
                 => String
                 -> LocalNode
                 -> a
                 -> (TestResult a -> Process ())
                 -> MVar ()
                 -> Assertion
delayedAssertion note localNode expected testProc lock = do
  result <- newEmptyMVar
  _ <- forkProcess localNode $ do
         acquire lock
         finally (testProc result)
                 (release lock)
  assertComplete note result expected
  where acquire lock' = liftIO $ takeMVar lock'
        release lock' = liftIO $ putMVar lock' ()

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
  tracer <- startTracer $ \ev -> do
    say "in spawn tracer..."
    case ev of
      (TraceEvSpawned p) -> liftIO $ putMVar evSpawned p
      (TraceEvDied p r)  -> liftIO $ putMVar evDied (p, r)
      _ -> return ()

  (sp, rp) <- newChan
  pid <- spawnLocal $ sendChan sp ()
  () <- receiveChan rp

  tracedAlive <- liftIO $ takeMVar evSpawned
  (tracedDead, tracedReason) <- liftIO $ takeMVar evDied

  mref <- monitor tracer
  stopTracer -- this is asynchronous, so we need to wait...
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              ((\_ -> return ()))
    ]
  say "seen the death of tracer"
  setTraceFlags defaultTraceFlags
  say "finishing setting default flags"
  stash result (tracedAlive  == pid &&
                tracedDead   == pid &&
                tracedReason == DiedNormal)

testTraceRecvExplicitPid :: TestResult Bool -> Process ()
testTraceRecvExplicitPid result = do
  res <- liftIO $ newEmptyMVar
  pid <- spawnLocal $ do
    self <- getSelfPid
    expect >>= (flip sendChan) self
  withFlags defaultTraceFlags {
    traceRecv = traceOnly [pid]
    } $ do
    withTracer
      (\ev ->
        case ev of
          (TraceEvReceived pid' _) -> stash res (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res' <- liftIO $ takeMVar res
        stash result (res' && (p == pid))
  return ()

testTraceRecvNamedPid :: TestResult Bool -> Process ()
testTraceRecvNamedPid result = do
  res <- liftIO $ newEmptyMVar
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
          (TraceEvReceived pid' _) -> stash res (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res' <- liftIO $ takeMVar res
        stash result (res' && (p == pid))
  return ()

testTraceLayering :: TestResult () -> Process ()
testTraceLayering result = do
  pid <- spawnLocal $ do
    getSelfPid >>= register "foobar"
    () <- expect
    traceMessage ("traceMsg", 123 :: Int)
    return ()
  withFlags defaultTraceFlags {
      traceDied    = traceOnly [pid]
    , traceRecv    = traceOnly ["foobar"]
    } $ doTest pid result
  return ()
  where
    doTest :: ProcessId -> MVar () -> Process ()
    doTest pid result' = do
      -- TODO: this is pretty gross, even for a test case
      died <- liftIO $ newEmptyMVar
      withTracer
       (\ev ->
         case ev of
           TraceEvDied _ _ -> liftIO $ putMVar died ()
           _               -> return ())
       ( do {
           recv <- liftIO $ newEmptyMVar
         ; withTracer
          (\ev' ->
            case ev' of
              TraceEvReceived _ _ -> liftIO $ putMVar recv ()
              _                   -> return ())
          ( do {
              user <- liftIO $ newEmptyMVar
            ; withTracer
                (\ev'' ->
                  case ev'' of
                    TraceEvUser _ -> liftIO $ putMVar user ()
                    _             -> return ())
                (send pid () >> (liftIO $ takeMVar user))
            ; liftIO $ takeMVar recv
            })
          ; liftIO $ takeMVar died
          })
      liftIO $ putMVar result' ()

tests :: LocalNode -> IO [Test]
tests node1 = do
  -- if we execute the test cases in parallel, the
  -- various tracers will race with one another and
  -- we'll get garbage results (or worse, deadlocks)
  lock <- liftIO $ newMVar ()
  enabled <- checkTraceEnabled
  case enabled of
    True ->
      return [
        testGroup "Tracing" [
           testCase "Spawn Tracing"
             (delayedAssertion
              "expected dead process-info to be ProcessInfoNone"
              node1 True testSpawnTracing lock)
         , testCase "Recv Tracing (Explicit Pid)"
             (delayedAssertion
              "expected a recv trace for the supplied pid"
              node1 True testTraceRecvExplicitPid lock)
         , testCase "Recv Tracing (Named Pid)"
             (delayedAssertion
              "expected a recv trace for the process registered as 'foobar'"
              node1 True testTraceRecvNamedPid lock)
         , testCase "Trace Layering"
             (delayedAssertion
              "expected blah"
              node1 () testTraceLayering lock)
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

