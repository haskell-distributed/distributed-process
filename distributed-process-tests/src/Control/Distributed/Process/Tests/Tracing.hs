{-# LANGUAGE DeriveDataTypeable        #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
module Control.Distributed.Process.Tests.Tracing (tests) where

import Control.Distributed.Process.Tests.Internal.Utils
import Network.Transport.Test (TestTransport(..))

import Control.Applicative ((<*))
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , newMVar
  , putMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Debug
import Control.Distributed.Process.Management
  ( MxEvent(..)
  )
import qualified Control.Exception as IO (bracket)
import Data.List (isPrefixOf, isSuffixOf)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, log)
#else
import Prelude hiding ((<*))
#endif

import Test.Framework
  ( Test
  , testGroup
  )
import Test.Framework.Providers.HUnit (testCase)
import System.Environment (getEnvironment)
-- These are available in System.Environment only since base 4.7
import System.SetEnv (setEnv, unsetEnv)


testSpawnTracing :: TestResult Bool -> Process ()
testSpawnTracing result = do
  setTraceFlags defaultTraceFlags {
      traceSpawned = (Just TraceAll)
    , traceDied    = (Just TraceAll)
    }

  evSpawned <- liftIO $ newEmptyMVar
  evDied <- liftIO $ newEmptyMVar
  tracer <- startTracer $ \ev -> do
    case ev of
      (MxSpawned p)       -> liftIO $ putMVar evSpawned p
      (MxProcessDied p r) -> liftIO $ putMVar evDied (p, r)
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
  setTraceFlags defaultTraceFlags
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
          (MxReceived pid' _) -> stash res (pid == pid')
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
          (MxReceived pid' _) -> stash res (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res' <- liftIO $ takeMVar res
        stash result (res' && (p == pid))
  return ()

testTraceSending :: TestResult Bool -> Process ()
testTraceSending result = do
  pid <- spawnLocal $ (expect :: Process String) >> return ()
  self <- getSelfPid
  res <- liftIO $ newEmptyMVar
  withFlags defaultTraceFlags { traceSend = traceOn } $ do
    withTracer
      (\ev ->
        case ev of
          (MxSent to from msg) -> do
            mS <- unwrapMessage msg :: Process (Maybe String)
            case mS of
              (Just s) -> do stash res (to == pid && from == self && s == "hello there")
                             stash res (to == pid && from == self)
              _        -> die "failed state invariant, message type unmatched..."
          _ ->
            return ()) $ do
        send pid "hello there"
  res' <- liftIO $ takeMVar res
  stash result res'

testTraceRegistration :: TestResult Bool -> Process ()
testTraceRegistration result = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    self <- getSelfPid
    () <- expect
    register "foobar" self
    sendChan sp ()
    () <- expect
    return ()
  res <- liftIO $ newEmptyMVar
  withFlags defaultTraceFlags { traceRegistered = traceOn } $ do
    withTracer
      (\ev ->
        case ev of
          MxRegistered p s ->
            stash res (p == pid && s == "foobar")
          _ ->
            return ()) $ do
        _ <- monitor pid
        send pid ()
        () <- receiveChan rp
        send pid ()
        receiveWait [
          match (\(ProcessMonitorNotification _ _ _) -> return ())
          ]
  res' <- liftIO $ takeMVar res
  stash result res'

testTraceUnRegistration :: TestResult Bool -> Process ()
testTraceUnRegistration result = do
  pid <- spawnLocal $ do
    () <- expect
    unregister "foobar"
    () <- expect
    return ()
  register "foobar" pid
  res <- liftIO $ newEmptyMVar
  withFlags defaultTraceFlags { traceUnregistered = traceOn } $ do
    withTracer
      (\ev ->
        case ev of
          MxUnRegistered p n -> do
            stash res (p == pid && n == "foobar")
            send pid ()
          _ ->
            return ()) $ do
        mref <- monitor pid
        send pid ()
        receiveWait [
          matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                  (\_ -> return ())
          ]
  res' <- liftIO $ takeMVar res
  stash result res'

testTraceLayering :: TestResult () -> Process ()
testTraceLayering result = do
  pid <- spawnLocal $ do
    getSelfPid >>= register "foobar"
    () <- expect
    traceMessage ("traceMsg", 123 :: Int)
    return ()
  withFlags defaultTraceFlags {
      traceDied = traceOnly [pid]
    , traceRecv = traceOnly ["foobar"]
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
           MxProcessDied _ _ -> liftIO $ putMVar died ()
           _                 -> return ())
       ( do {
           recv <- liftIO $ newEmptyMVar
         ; withTracer
            (\ev' ->
              case ev' of
                MxReceived _ _ -> liftIO $ putMVar recv ()
                _                   -> return ())
            ( do {
                user <- liftIO $ newEmptyMVar
              ; withTracer
                  (\ev'' ->
                    case ev'' of
                      MxUser _ -> liftIO $ putMVar user ()
                      _             -> return ())
                  (send pid () >> (liftIO $ takeMVar user))
              ; liftIO $ takeMVar recv
              })
         ; liftIO $ takeMVar died
         })
      liftIO $ putMVar result' ()

testRemoteTraceRelay :: TestTransport -> TestResult Bool -> Process ()
testRemoteTraceRelay TestTransport{..} result =
  let flags = defaultTraceFlags { traceSpawned = traceOn }
  in do
    node2 <- liftIO $ newLocalNode testTransport initRemoteTable
    mvNid <- liftIO $ newEmptyMVar

    -- As well as needing node2's NodeId, we want to
    -- redirect all its logs back here, to avoid generating
    -- garbage on stderr for the duration of the test run.
    -- Here we set up that relay, and then wait for a signal
    -- that the tracer (on node1) has seen the expected
    -- MxSpawned message, at which point we're finished

    pid <- splinchLogger node2 mvNid
    nid <- liftIO $ takeMVar mvNid
    mref <- monitor pid
    observedPid <- liftIO $ newEmptyMVar
    spawnedPid <- liftIO $ newEmptyMVar
    setTraceFlagsRemote flags nid

    withFlags defaultTraceFlags { traceSpawned = traceOn } $ do
      withTracer
        (\ev ->
          case ev of
            MxSpawned p -> stash observedPid p >> send pid ()
            _                -> return ()) $ do
          relayPid <- startTraceRelay nid
          liftIO $ threadDelay 1000000
          p <- liftIO $ forkProcess node2 $ do
            expectTimeout 1000000 :: Process (Maybe ())
            return ()
          stash spawnedPid p

          -- Now we wait for (the outer) pid to exit. This won't happen until
          -- our tracer has seen the trace event for `p' and sent `p' the
          -- message it's waiting for prior to exiting
          receiveWait [
            matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                    (\_ -> return ())
            ]

          relayRef <- monitor relayPid
          kill relayPid "stop"
          receiveWait [
            matchIf (\(ProcessMonitorNotification rref' _ _) -> rref' == relayRef)
                    (\_ -> return ())
            ]
    observed <- liftIO $ takeMVar observedPid
    expected <- liftIO $ takeMVar spawnedPid
    stash result (observed == expected)
    -- and just to be polite...
    liftIO $ closeLocalNode node2

  where
    splinchLogger n2 mv = do
      mLog <- whereis "logger"
      case mLog of
        Nothing   -> die "no logger registered"
        Just log' -> do liftIO $ forkProcess n2 $ do
                          logRelay <- spawnLocal $ relay log'
                          reregister "logger" logRelay
                          getSelfNode >>= stash mv >> (expect :: Process ())


-- | Sets the value of an environment variable while executing the given IO
-- computation and restores the preceeding value upon completion.
withEnv :: String -> String -> IO a -> IO a
withEnv var val =
    IO.bracket (fmap (lookup var) getEnvironment <* setEnv var val)
               (maybe (unsetEnv var) (setEnv var))
    . const

-- | Tests that one and only one interesting trace message is produced when a
-- given action is performed. A message is considered interesting when the given
-- function return @True@.
testSystemLoggerMsg :: TestTransport
                    -> Process a
                    -> (a -> String -> Bool)
                    -> IO ()
testSystemLoggerMsg t action interestingMessage =
    withEnv "DISTRIBUTED_PROCESS_TRACE_CONSOLE" "yes" $
    withEnv "DISTRIBUTED_PROCESS_TRACE_FLAGS" "pdnusrl" $ do
    n <- newLocalNode (testTransport t) initRemoteTable

    runProcess n $ do
      self <- getSelfPid
      reregister "trace.logger" self
      a <- action
      let interestingMessage' (_ :: String, msg) = interestingMessage a msg
      -- Wait for the trace message.
      receiveWait [ matchIf interestingMessage' $ const $ return () ]
      -- Only one interesting message should arrive.
      expectedTimeout <- receiveTimeout
                           100000
                           [ matchIf interestingMessage' $ const $ return () ]
      case expectedTimeout of
        Nothing -> return ()
        Just _  -> die "Unexpected message arrived..."


-- | Tests that one and only one trace message is produced when a message is
-- received.
testSystemLoggerMxReceive :: TestTransport -> IO ()
testSystemLoggerMxReceive t = testSystemLoggerMsg t
    (getSelfPid >>= flip send ())
    (\_ msg -> "MxReceived" `isPrefixOf` msg
             -- discard traces of internal messages
          && not (":: RegisterReply" `isSuffixOf` msg)
    )

-- | Tests that one and only one trace message is produced when a message is
-- sent.
testSystemLoggerMxSent :: TestTransport -> IO ()
testSystemLoggerMxSent t = testSystemLoggerMsg t
    (getSelfPid >>= flip send ())
    (const $ isPrefixOf "MxSent")

-- | Tests that one and only one trace message is produced when a process dies.
testSystemLoggerMxProcessDied :: TestTransport -> IO ()
testSystemLoggerMxProcessDied t = testSystemLoggerMsg t
    (spawnLocal $ return ())
    (\pid -> isPrefixOf $ "MxProcessDied " ++ show pid)

-- | Tests that one and only one trace message appears when a process spawns.
testSystemLoggerMxSpawned :: TestTransport -> IO ()
testSystemLoggerMxSpawned t = testSystemLoggerMsg t
    (spawnLocal $ return ())
    (\pid -> isPrefixOf $ "MxSpawned " ++ show pid)

-- | Tests that one and only one trace message appears when a process is
-- registered.
testSystemLoggerMxRegistered :: TestTransport -> IO ()
testSystemLoggerMxRegistered t = testSystemLoggerMsg t
    (getSelfPid >>= register "a" >> getSelfPid)
    (\self -> isPrefixOf $ "MxRegistered " ++ show self ++ " " ++ show "a")

-- | Tests that one and only one trace message appears when a process is
-- unregistered.
testSystemLoggerMxUnRegistered :: TestTransport -> IO ()
testSystemLoggerMxUnRegistered t = testSystemLoggerMsg t
    (getSelfPid >>= register "a" >> unregister "a" >> getSelfPid)
    (\self -> isPrefixOf $ "MxUnRegistered " ++ show self ++ " " ++ show "a")

tests :: TestTransport -> IO [Test]
tests testtrans@TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  -- if we execute the test cases in parallel, the
  -- various tracers will race with one another and
  -- we'll get garbage results (or worse, deadlocks)
  lock <- liftIO $ newMVar ()
  return [
    testGroup "Tracing" [
           testCase "Spawn Tracing"
             (synchronisedAssertion
              "expected dead process-info to be ProcessInfoNone"
              node1 True testSpawnTracing lock)
         , testCase "Recv Tracing (Explicit Pid)"
             (synchronisedAssertion
              "expected a recv trace for the supplied pid"
              node1 True testTraceRecvExplicitPid lock)
         , testCase "Recv Tracing (Named Pid)"
             (synchronisedAssertion
              "expected a recv trace for the process registered as 'foobar'"
              node1 True testTraceRecvNamedPid lock)
         , testCase "Trace Send(er)"
             (synchronisedAssertion
              "expected a 'send' trace with the requisite fields set"
              node1 True testTraceSending lock)
         , testCase "Trace Registration"
              (synchronisedAssertion
               "expected a 'registered' trace"
               node1 True testTraceRegistration lock)
         , testCase "Trace Unregistration"
              (synchronisedAssertion
               "expected an 'unregistered' trace"
               node1 True testTraceUnRegistration lock)
         , testCase "Trace Layering"
              (synchronisedAssertion
               "expected blah"
               node1 () testTraceLayering lock)
         , testCase "Remote Trace Relay"
              (synchronisedAssertion
               "expected blah"
               node1 True (testRemoteTraceRelay testtrans) lock)
         , testGroup "SystemLoggerTracer"
           [ testCase "MxReceive" $ testSystemLoggerMxReceive testtrans
           , testCase "MxSent" $ testSystemLoggerMxSent testtrans
           , testCase "MxProcessDied" $ testSystemLoggerMxProcessDied testtrans
           , testCase "MxSpawned" $ testSystemLoggerMxSpawned testtrans
           , testCase "MxRegistered" $ testSystemLoggerMxRegistered testtrans
           , testCase "MxUnRegistered" $ testSystemLoggerMxUnRegistered testtrans
           ]
         ] ]
