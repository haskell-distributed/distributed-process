{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}

module Main where

import Control.Concurrent.MVar
import Control.Concurrent.STM.TQueue
 ( newTQueueIO
 , readTQueue
 , writeTQueue
 )
import Control.Exception (SomeException)
import Control.DeepSeq (NFData)
import Control.Distributed.Process hiding (call, send, catch, sendChan)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Extras hiding (__remoteTable, monitor)
import Control.Distributed.Process.Async hiding (check)
import Control.Distributed.Process.ManagedProcess hiding (reject)
import qualified Control.Distributed.Process.ManagedProcess.Server.Priority as P (Message)
import Control.Distributed.Process.ManagedProcess.Server.Priority
import Control.Distributed.Process.SysTest.Utils
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Timer hiding (runAfter)
import Control.Distributed.Process.Serializable()
import Control.Monad
import Control.Monad.Catch (catch)

import Data.Binary
import Data.Either (rights)
import Data.List (isInfixOf)
import Data.Typeable (Typeable)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import TestUtils
import ManagedProcessCommon

import qualified Network.Transport as NT

import GHC.Generics (Generic)

-- utilities

server :: Process (ProcessId, (MVar ExitReason))
server = mkServer Terminate

mkServer :: UnhandledMessagePolicy
         -> Process (ProcessId, (MVar ExitReason))
mkServer policy =
  let s = standardTestServer policy
      p = s `prioritised` ([] :: [DispatchPriority ()])
  in do
    exitReason <- liftIO $ newEmptyMVar
    pid <- spawnLocal $ do
       catch  ((pserve () (statelessInit Infinity) p >> stash exitReason ExitNormal)
                `catchesExit` [
                    (\_ msg -> do
                      mEx <- unwrapMessage msg :: Process (Maybe ExitReason)
                      case mEx of
                        Nothing -> return Nothing
                        Just r  -> stash exitReason r >>= return . Just
                    )
                 ])
              (\(e :: SomeException) -> stash exitReason $ ExitOther (show e))
    return (pid, exitReason)

explodingServer :: ProcessId
                -> Process (ProcessId, MVar ExitReason)
explodingServer pid =
  let srv = explodingTestProcess pid
      pSrv = srv `prioritised` ([] :: [DispatchPriority s])
  in do
    exitReason <- liftIO newEmptyMVar
    spid <- spawnLocal $ do
       catch  (pserve () (statelessInit Infinity) pSrv >> stash exitReason ExitNormal)
              (\(e :: SomeException) -> do
                -- say "died in handler..."
                stash exitReason $ ExitOther (show e))
    return (spid, exitReason)

data GetState = GetState
  deriving (Typeable, Generic, Show, Eq)
instance Binary GetState where
instance NFData GetState where

data MyAlarmSignal = MyAlarmSignal
  deriving (Typeable, Generic, Show, Eq)
instance Binary MyAlarmSignal where
instance NFData MyAlarmSignal where

mkPrioritisedServer :: Process ProcessId
mkPrioritisedServer =
  let p = procDef `prioritised` ([
               prioritiseInfo_ (\MyAlarmSignal   -> setPriority 10)
             , prioritiseCast_ (\(_ :: String)   -> setPriority 2)
             , prioritiseCall_ (\(cmd :: String) -> (setPriority (length cmd)) :: Priority ())
             ] :: [DispatchPriority [Either MyAlarmSignal String]]
          ) :: PrioritisedProcessDefinition [(Either MyAlarmSignal String)]
  in spawnLocal $ pserve () (initWait Infinity) p
  where
    initWait :: Delay
             -> InitHandler () [Either MyAlarmSignal String]
    initWait d () = do
      () <- expect
      return $ InitOk [] d

    procDef :: ProcessDefinition [(Either MyAlarmSignal String)]
    procDef =
      defaultProcess {
            apiHandlers = [
               handleCall (\s GetState -> reply (reverse s) s)
             , handleCall (\s (cmd :: String) -> reply () ((Right cmd):s))
             , handleCast (\s (cmd :: String) -> continue ((Right cmd):s))
            ]
          , infoHandlers = [
               handleInfo (\s (sig :: MyAlarmSignal) -> continue ((Left sig):s))
            ]
          , unhandledMessagePolicy = Drop
          , timeoutHandler         = \_ _ -> stop $ ExitOther "timeout"
          } :: ProcessDefinition [(Either MyAlarmSignal String)]

mkOverflowHandlingServer :: (PrioritisedProcessDefinition Int ->
                             PrioritisedProcessDefinition Int)
                         -> Process ProcessId
mkOverflowHandlingServer modIt =
  let p = procDef `prioritised` ([
               prioritiseCall_ (\GetState -> setPriority 99 :: Priority Int)
             , prioritiseCast_ (\(_ :: String) -> setPriority 1)
             ] :: [DispatchPriority Int]
          ) :: PrioritisedProcessDefinition Int
  in spawnLocal $ pserve () (initWait Infinity) (modIt p)
  where
    initWait :: Delay
             -> InitHandler () Int
    initWait d () = return $ InitOk 0 d

    procDef :: ProcessDefinition Int
    procDef =
      defaultProcess {
            apiHandlers = [
               handleCall (\s GetState -> reply s s)
             , handleCast (\s (_ :: String) -> continue $ s + 1)
            ]
          } :: ProcessDefinition Int

launchStmServer :: CallHandler () String String -> Process StmServer
launchStmServer handler = do
  (inQ, replyQ) <- liftIO $ do
    cIn <- newTQueueIO
    cOut <- newTQueueIO
    return (cIn, cOut)

  let procDef = statelessProcess {
                  externHandlers = [
                    handleCallExternal
                      (readTQueue inQ)
                      (writeTQueue replyQ)
                      handler
                  ]
                , apiHandlers = [
                    action (\() -> stop_ ExitNormal)
                  ]
                }

  let p = procDef `prioritised` ([
               prioritiseCast_ (\() -> setPriority 99 :: Priority ())
             , prioritiseCast_ (\(_ :: String) -> setPriority 100)
             ] :: [DispatchPriority ()]
          ) :: PrioritisedProcessDefinition ()

  pid <- spawnLocal $ pserve () (statelessInit Infinity) p
  return $ StmServer pid inQ replyQ

launchStmOverloadServer :: Process (ProcessId, ControlPort String)
launchStmOverloadServer = do
  cc <- newControlChan :: Process (ControlChannel String)
  let cp = channelControlPort cc

  let procDef = statelessProcess {
                  externHandlers = [
                    handleControlChan_ cc (\(_ :: String) -> continue_)
                  ]
                , apiHandlers = [
                    handleCast (\s sp -> sendChan sp () >> continue s)
                  ]
                }

  let p = procDef `prioritised` ([
               prioritiseCast_ (\() -> setPriority 99 :: Priority ())
             ] :: [DispatchPriority ()]
          ) :: PrioritisedProcessDefinition ()

  pid <- spawnLocal $ pserve () (statelessInit Infinity) p
  return (pid, cp)

data Foo = Foo deriving (Show)

launchFilteredServer :: ProcessId -> Process (ProcessId, ControlPort (SendPort Int))
launchFilteredServer us = do
  cc <- newControlChan :: Process (ControlChannel (SendPort Int))
  let cp = channelControlPort cc

  let procDef = defaultProcess {
                  externHandlers = [
                    handleControlChan cc (\s (p :: SendPort Int) -> sendChan p s >> continue s)
                  ]
                , apiHandlers = [
                    handleCast (\s sp -> sendChan sp () >> continue s)
                  , handleCall_ (\(s :: String) -> return s)
                  , handleCall_ (\(i :: Int) -> return i)
                  ]
                , unhandledMessagePolicy = DeadLetter us
                } :: ProcessDefinition Int

  let p = procDef `prioritised` ([
               prioritiseCast_ (\() -> setPriority 1 :: Priority ())
             , prioritiseCall_ (\(_ :: String) -> setPriority 100 :: Priority String)
             ] :: [DispatchPriority Int]
          ) :: PrioritisedProcessDefinition Int

  let rejectUnchecked =
        rejectApi Foo :: Int -> P.Message String String -> Process (Filter Int)

  let p' = p {
    filters = [
      store  (+1)
    , ensure (>0)  -- a bit pointless, but we're just checking the API

    , check $ api_ (\(s :: String) -> return $ "checked-" `isInfixOf` s) rejectUnchecked
    , check $ info (\_ (_ :: MonitorRef, _ :: ProcessId) -> return False) $ reject Foo
    , refuse ((> 10) :: Int -> Bool)
    ]
  }

  pid <- spawnLocal $ pserve 0 (\c -> return $ InitOk c Infinity) p'
  return (pid, cp)

testFilteringBehavior :: TestResult Bool -> Process ()
testFilteringBehavior result = do
  us <- getSelfPid
  (sp, rp) <- newChan
  (pid, cp) <- launchFilteredServer us
  mRef <- monitor pid

  sendControlMessage cp sp

  r <- receiveChan rp :: Process Int
  when (r > 1) $ stash result False >> die "we're done..."

  Left _ <- safeCall pid "bad-input" :: Process (Either ExitReason String)

  send pid (mRef, us)  -- server doesn't like this, dead letters it...
  -- back to us
  void $ receiveWait [ matchIf (\(m, p) -> m == mRef && p == us) return ]

  sendControlMessage cp sp

  r2 <- receiveChan rp :: Process Int
  when (r2 < 3) $ stash result False >> die "we're done again..."

  -- server also doesn't like this, and sends it right back (via \DeadLetter us/)
  send pid (25 :: Int)

  m <- receiveWait [ matchIf (== 25) return ] :: Process Int
  stash result $ m == 25
  kill pid "done"

testSafeExecutionContext :: TestResult Bool -> Process ()
testSafeExecutionContext result = do
  let t = (asTimeout $ seconds 5)
  (sigSp, rp) <- newChan
  (wp, lp) <- newChan
  let def = statelessProcess
            { apiHandlers  = [ handleCall_ (\(m :: String) -> stranded rp wp Nothing >> return m) ]
            , infoHandlers = [ handleInfo  (\s (m :: String) -> stranded rp wp (Just m) >> continue s) ]
            , exitHandlers = [ handleExit  (\_ s (_ :: String) -> continue s) ]
            } `prioritised` []

  let spec = def { filters = [
                     safe    (\_ (_ :: String) -> True)
                   , apiSafe (\_ (_ :: String) (_ :: Maybe String) -> True)
                   ]
                 }

  pid <- spawnLocal $ pserve () (statelessInit Infinity) spec
  send pid "hello"  -- pid can't process this as it's stuck waiting on rp

  sleep $ seconds 3
  exit pid "ooops"  -- now we force an exit signal once the receiveWait finishes
  sendChan sigSp () -- and allow the receiveWait to complete
  send pid "hi again"

  -- at this point, "hello" should still be in the backing queue/mailbox
  sleep $ seconds 3

  -- We should still be seeing "hello", since the 'safe' block saved us from
  -- losing a message when we handled and swallowed the exit signal.
  -- We should not see "hi again" until after "hello" has been processed
  h <- receiveChanTimeout t lp
  -- say $ "first response: " ++ (show h)
  let a1 = h == (Just "hello")

  sleep $ seconds 3

  -- now we should have "hi again" waiting in the mailbox...
  sendChan sigSp ()  -- we must release the handler a second time...
  h2 <- receiveChanTimeout t lp
  -- say $ "second response: " ++ (show h2)
  let a2 = h2 == (Just "hi again")

  void $ spawnLocal $ call pid "reply-please" >>= sendChan wp

  -- the call handler should be stuck waiting on rp
  Nothing <- receiveChanTimeout (asTimeout $ seconds 2) lp

  -- now let's force an exit, then release the handler to see if it runs again...
  exit pid "ooops2"

  sleep $ seconds 2
  sendChan sigSp ()

  h3 <- receiveChanTimeout t lp
--  say $ "third response: " ++ (show h3)
  let a3 = h3 == (Just "reply-please")

  stash result $ a1 && a2 && a3

  where

    stranded :: ReceivePort () -> SendPort String -> Maybe String -> Process ()
    stranded gate chan str = do
      -- say $ "stranded with " ++ (show str)
      void $ receiveWait [ matchChan gate return ]
      sleep $ seconds 1
      case str of
        Nothing -> return ()
        Just s  -> sendChan chan s

testExternalTimedOverflowHandling :: TestResult Bool -> Process ()
testExternalTimedOverflowHandling result = do
  (pid, cp) <- launchStmOverloadServer -- default 10k mailbox drain limit
  wrk <- spawnLocal $ mapM_ (sendControlMessage cp . show) ([1..500000] :: [Int])

  sleep $ milliSeconds 250 -- give the worker time to start spamming the server...

  (sp, rp) <- newChan
  cast pid sp -- tell the server we're expecting a reply

  -- it might take "a while" for us to get through the first 10k messages
  -- from our chatty friend wrk, before we finally get our control message seen
  -- by the reader/listener loop, and in fact timing wise we don't even know when
  -- our message will arrive, since we're racing with wrk to communicate with
  -- the server. It's important therefore to give sufficient time for the right
  -- conditions to occur so that our message is finally received and processed,
  -- yet we don't want to lock up the build for 10-20 mins either. This value
  -- of 30 seconds seems like a reasonable compromise.
  answer <- receiveChanTimeout (asTimeout $ seconds 30) rp

  stash result $ answer == Just ()
  kill wrk "done"
  kill pid "done"

testExternalCall :: TestResult Bool -> Process ()
testExternalCall result = do
  let txt = "hello stm-call foo"
  srv <- launchStmServer (\st (msg :: String) -> reply msg st)
  echoStm srv txt >>= stash result . (== Right txt)
  killProc srv "done"

testTimedOverflowHandling :: TestResult Bool -> Process ()
testTimedOverflowHandling result = do
  pid <- mkOverflowHandlingServer (\s -> s { recvTimeout = RecvTimer $ within 3 Seconds })
  wrk <- spawnLocal $ mapM_ (cast pid . show) ([1..500000] :: [Int])

  sleep $ seconds 1 -- give the worker time to start spamming us...
  cast pid "abc" -- just getting in line here...

  st <- call pid GetState :: Process Int
  -- the result of GetState is a list of messages in reverse insertion order
  stash result $ st > 0
  kill wrk "done"
  kill pid "done"

testOverflowHandling :: TestResult Bool -> Process ()
testOverflowHandling result = do
  pid <- mkOverflowHandlingServer (\s -> s { recvTimeout = RecvMaxBacklog 100 })
  wrk <- spawnLocal $ mapM_ (cast pid . show) ([1..50000] :: [Int])

  sleep $ seconds 1
  cast pid "abc" -- just getting in line here...

  st <- call pid GetState :: Process Int
  -- the result of GetState is a list of messages in reverse insertion order
  stash result $ st > 0
  kill wrk "done"
  kill pid "done"

testInfoPrioritisation :: TestResult Bool -> Process ()
testInfoPrioritisation result = do
  pid <- mkPrioritisedServer
  -- the server (pid) is configured to wait for () during its init
  -- so we can fill up its mailbox with String messages, and verify
  -- that the alarm signal (which is prioritised *above* these)
  -- actually gets processed first despite the delivery order
  cast pid "hello"
  cast pid "prioritised"
  cast pid "world"
  -- note that these have to be a "bare send"
  send pid MyAlarmSignal
  -- tell the server it can move out of init and start processing messages
  send pid ()
  st <- call pid GetState :: Process [Either MyAlarmSignal String]
  -- the result of GetState is a list of messages in reverse insertion order
  case head st of
    Left MyAlarmSignal -> stash result True
    _ -> stash result False

testUserTimerHandling :: TestResult Bool -> Process ()
testUserTimerHandling result = do
  us <- getSelfPid
  let p = (procDef us) `prioritised` ([
               prioritiseInfo_ (\MyAlarmSignal -> setPriority 100)
             ] :: [DispatchPriority ()]
          ) :: PrioritisedProcessDefinition ()
  pid <- spawnLocal $ pserve () (statelessInit Infinity) p
  cast pid ()
  expect >>= stash result . (== MyAlarmSignal)
  kill pid "goodbye..."

  where

    procDef :: ProcessId -> ProcessDefinition ()
    procDef us =
      statelessProcess {
            apiHandlers = [
              handleCast (\s () -> evalAfter (seconds 5) MyAlarmSignal s)
            ]
          , infoHandlers = [
               handleInfo (\s (sig :: MyAlarmSignal) -> send us sig >> continue s)
            ]
          , unhandledMessagePolicy = Drop
          } :: ProcessDefinition ()


testCallPrioritisation :: TestResult Bool -> Process ()
testCallPrioritisation result = do
  pid <- mkPrioritisedServer
  asyncRefs <- (mapM (callAsync pid)
                    ["first", "the longest", "commands", "we do prioritise"])
                 :: Process [Async ()]
  -- NB: This sleep is really important - the `init' function is waiting
  -- (selectively) on the () signal to go, and if it receives this *before*
  -- the async worker has had a chance to deliver the longest string message,
  -- our test will fail. Such races are /normal/ given that the async worker
  -- runs in another process and delivery order between multiple processes
  -- is undefined (and in practise, paritally depenendent on the scheduler)
  sleep $ seconds 1
  send pid ()
  _ <- mapM wait asyncRefs :: Process [AsyncResult ()]
  st <- call pid GetState :: Process [Either MyAlarmSignal String]
  let ms = rights st
  stash result $ ms == ["we do prioritise", "the longest", "commands", "first"]

tests :: NT.Transport  -> IO [Test]
tests transport = do
  localNode <- newLocalNode transport initRemoteTable
  return [
        testGroup "basic server functionality matches un-prioritised processes" [
            testCase "basic call with explicit server reply"
            (delayedAssertion
             "expected a response from the server"
             localNode (Just "foo") (testBasicCall $ wrap server))
          , testCase "basic call with implicit server reply"
            (delayedAssertion
             "expected n * 2 back from the server"
             localNode (Just 4) (testBasicCall_ $ wrap server))
          , testCase "basic cast with manual send and explicit server continue"
            (delayedAssertion
             "expected pong back from the server"
             localNode (Just "pong") (testBasicCast $ wrap server))
          , testCase "cast and explicit server timeout"
            (delayedAssertion
             "expected the server to stop after the timeout"
             localNode (Just $ ExitOther "timeout") (testControlledTimeout $ wrap server))
          , testCase "unhandled input when policy = Terminate"
            (delayedAssertion
             "expected the server to stop upon receiving unhandled input"
             localNode (Just $ ExitOther "UnhandledInput")
             (testTerminatePolicy $ wrap server))
          , testCase "unhandled input when policy = Drop"
            (delayedAssertion
             "expected the server to ignore unhandled input and exit normally"
             localNode Nothing (testDropPolicy $ wrap (mkServer Drop)))
          , testCase "unhandled input when policy = DeadLetter"
            (delayedAssertion
             "expected the server to forward unhandled messages"
             localNode (Just ("UNSOLICITED_MAIL", 500 :: Int))
             (testDeadLetterPolicy $ \p -> mkServer (DeadLetter p)))
          , testCase "incoming messages are ignored whilst hibernating"
            (delayedAssertion
             "expected the server to remain in hibernation"
             localNode True (testHibernation $ wrap server))
          , testCase "long running call cancellation"
            (delayedAssertion "expected to get AsyncCancelled"
             localNode True (testKillMidCall $ wrap server))
          , testCase "server rejects call"
             (delayedAssertion "expected server to send CallRejected"
              localNode (ExitOther "invalid-call") (testServerRejectsMessage $ wrap server))
          , testCase "simple exit handling"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode Nothing (testSimpleErrorHandling $ explodingServer))
          , testCase "alternative exit handlers"
            (delayedAssertion "expected handler to catch exception and continue"
             localNode Nothing (testAlternativeErrorHandling $ explodingServer))
          ]
      , testGroup "Prioritised Mailbox Handling" [
            testCase "Info Message Prioritisation"
            (delayedAssertion "expected the info handler to be prioritised"
             localNode True testInfoPrioritisation)
          , testCase "Call Message Prioritisation"
            (delayedAssertion "expected the longest strings to be prioritised"
             localNode True testCallPrioritisation)
          , testCase "Size-Based Mailbox Overload Management"
            (delayedAssertion "expected the server loop to stop reading the mailbox"
             localNode True testOverflowHandling)
          , testCase "Timeout-Based Mailbox Overload Management"
            (delayedAssertion "expected the server loop to stop reading the mailbox"
             localNode True testTimedOverflowHandling)
          ]
       , testGroup "Advanced Server Interactions" [
            testCase "using callSTM to manage non-CH interactions"
            (delayedAssertion
             "expected the server to reply back via the TQueue"
             localNode True testExternalCall)
          , testCase "Timeout-Based Overload Management with Control Channels"
            (delayedAssertion "expected the server loop to reply"
             localNode True testExternalTimedOverflowHandling)
          , testCase "Complex pre/before filters"
             (delayedAssertion "expected verifiable filter actions"
              localNode True testFilteringBehavior)
          , testCase "Firing internal timeouts"
             (delayedAssertion "expected our info handler to run after the timeout"
              localNode True testUserTimerHandling)
          , testCase "Creating 'Safe' Handlers"
             (delayedAssertion "expected our handler to run on the old message"
              localNode True testSafeExecutionContext)
         ]
      ]

main :: IO ()
main = testMain $ tests
