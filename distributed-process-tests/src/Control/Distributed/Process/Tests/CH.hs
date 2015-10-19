module Control.Distributed.Process.Tests.CH (tests) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Network.Transport.Test (TestTransport(..))

import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.Foldable (forM_)
import Data.IORef
  ( readIORef
  , writeIORef
  , newIORef
  )
import Control.Concurrent (forkIO, threadDelay, myThreadId, throwTo, ThreadId, yield)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , readMVar
  )
import Control.Monad (replicateM_, replicateM, forever, void, unless, join)
import Control.Exception (SomeException, throwIO, ErrorCall(..))
import qualified Control.Exception as Ex (catch)
import Control.Applicative ((<$>), (<*>), pure, (<|>))
import qualified Network.Transport as NT (closeEndPoint, EndPointAddress)
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
  ( NodeId(nodeAddress)
  , LocalNode(localEndPoint)
  , ProcessExitException(..)
  , nullProcessId
  , createUnencodedMessage
  )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (Serializable)

import Test.HUnit (Assertion, assertFailure)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)
import Control.Rematch hiding (match)
import Control.Rematch.Run (Match(..))

newtype Ping = Ping ProcessId
  deriving (Typeable, Binary, Show)

newtype Pong = Pong ProcessId
  deriving (Typeable, Binary, Show)

--------------------------------------------------------------------------------
-- Supporting definitions                                                     --
--------------------------------------------------------------------------------

expectThat :: a -> Matcher a -> Assertion
expectThat a matcher = case res of
  MatchSuccess -> return ()
  (MatchFailure msg) -> assertFailure msg
  where res = runMatch matcher a

-- | Like fork, but throw exceptions in the child thread to the parent
forkTry :: IO () -> IO ThreadId
forkTry p = do
  tid <- myThreadId
  forkIO $ Ex.catch p (\e -> throwTo tid (e :: SomeException))

-- | The ping server from the paper
ping :: Process ()
ping = do
  Pong partner <- expect
  self <- getSelfPid
  send partner (Ping self)
  ping

-- | Quick and dirty synchronous version of whereisRemoteAsync
whereisRemote :: NodeId -> String -> Process (Maybe ProcessId)
whereisRemote nid string = do
  whereisRemoteAsync nid string
  WhereIsReply _ mPid <- expect
  return mPid

data Add       = Add    ProcessId Double Double deriving (Typeable)
data Divide    = Divide ProcessId Double Double deriving (Typeable)
data DivByZero = DivByZero deriving (Typeable)

instance Binary Add where
  put (Add pid x y) = put pid >> put x >> put y
  get = Add <$> get <*> get <*> get

instance Binary Divide where
  put (Divide pid x y) = put pid >> put x >> put y
  get = Divide <$> get <*> get <*> get

instance Binary DivByZero where
  put DivByZero = return ()
  get = return DivByZero

-- The math server from the paper
math :: Process ()
math = do
  receiveWait
    [ match (\(Add pid x y) -> send pid (x + y))
    , matchIf (\(Divide _   _ y) -> y /= 0)
              (\(Divide pid x y) -> send pid (x / y))
    , match (\(Divide pid _ _) -> send pid DivByZero)
    ]
  math

-- | Monitor or link to a remote node
monitorOrLink :: Bool            -- ^ 'True' for monitor, 'False' for link
              -> ProcessId       -- ^ Process to monitor/link to
              -> Maybe (MVar ()) -- ^ MVar to signal on once the monitor has been set up
              -> Process (Maybe MonitorRef)
monitorOrLink mOrL pid mSignal = do
  result <- if mOrL then Just <$> monitor pid
                    else link pid >> return Nothing
  -- Monitor is asynchronous, which usually does not matter but if we want a
  --  *specific* signal then it does. Therefore we wait until the MonitorRef is
  -- listed in the ProcessInfo and hope that this means the monitor has been set
  -- up.
  forM_ mSignal $ \signal -> do
    self <- getSelfPid
    spawnLocal $ do
      let waitForMOrL = do
            liftIO $ threadDelay 100000
            mpinfo <- getProcessInfo pid
            case mpinfo of
              Nothing -> waitForMOrL
              Just pinfo ->
               if mOrL then
                 unless (result == lookup self (infoMonitors pinfo)) waitForMOrL
               else
                 unless (elem self $ infoLinks pinfo) waitForMOrL
      waitForMOrL
      liftIO $ putMVar signal ()
  return result

monitorTestProcess :: ProcessId       -- Process to monitor/link to
                   -> Bool            -- 'True' for monitor, 'False' for link
                   -> Bool            -- Should we unmonitor?
                   -> DiedReason      -- Expected cause of death
                   -> Maybe (MVar ()) -- Signal for 'monitor set up'
                   -> MVar ()         -- Signal for successful termination
                   -> Process ()
monitorTestProcess theirAddr mOrL un reason monitorSetup done =
  catch (do mRef <- monitorOrLink mOrL theirAddr monitorSetup
            case (un, mRef) of
              (True, Nothing) -> do
                unlink theirAddr
                liftIO $ putMVar done ()
              (True, Just ref) -> do
                unmonitor ref
                liftIO $ putMVar done ()
              (False, ref) -> do
                ProcessMonitorNotification ref' pid reason' <- expect
                True <- return $ Just ref' == ref && pid == theirAddr && mOrL && reason == reason'
                liftIO $ putMVar done ()
        )
        (\(ProcessLinkException pid reason') -> do
            True <- return $ pid == theirAddr && not mOrL && not un && reason == reason'
            liftIO $ putMVar done ()
        )

--------------------------------------------------------------------------------
-- The tests proper                                                           --
--------------------------------------------------------------------------------

-- | Basic ping test
testPing :: TestTransport -> Assertion
testPing TestTransport{..} = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    pingServer <- readMVar serverAddr

    let numPings = 10000

    runProcess localNode $ do
      pid <- getSelfPid
      replicateM_ numPings $ do
        send pingServer (Pong pid)
        Ping _ <- expect
        return ()

    putMVar clientDone ()

  takeMVar clientDone

-- | Monitor a process on an unreachable node
testMonitorUnreachable :: TestTransport -> Bool -> Bool -> Assertion
testMonitorUnreachable TestTransport{..} mOrL un = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode expect
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    theirAddr <- readMVar deadProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un DiedDisconnect Nothing done

  takeMVar done

-- | Monitor a process which terminates normally
testMonitorNormalTermination :: TestTransport -> Bool -> Bool -> Assertion
testMonitorNormalTermination TestTransport{..} mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode $
      liftIO $ readMVar monitorSetup
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un DiedNormal (Just monitorSetup) done

  takeMVar done

-- | Monitor a process which terminates abnormally
testMonitorAbnormalTermination :: TestTransport -> Bool -> Bool -> Assertion
testMonitorAbnormalTermination TestTransport{..} mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  let err = userError "Abnormal termination"

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode . liftIO $ do
      readMVar monitorSetup
      throwIO err
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un (DiedException (show err)) (Just monitorSetup) done

  takeMVar done

-- | Monitor a local process that is already dead
testMonitorLocalDeadProcess :: TestTransport -> Bool -> Bool -> Assertion
testMonitorLocalDeadProcess TestTransport{..} mOrL un = do
  processAddr <- newEmptyMVar
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  forkIO $ do
    addr <- forkProcess localNode $ return ()
    putMVar processAddr addr

  forkIO $ do
    theirAddr <- readMVar processAddr
    runProcess localNode $ do
      monitor theirAddr
      -- wait for the process to die
      ProcessMonitorNotification _ _ _ <- expect
      monitorTestProcess theirAddr mOrL un DiedUnknownId Nothing done

  takeMVar done

-- | Monitor a remote process that is already dead
testMonitorRemoteDeadProcess :: TestTransport -> Bool -> Bool -> Assertion
testMonitorRemoteDeadProcess TestTransport{..} mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedUnknownId Nothing done

  takeMVar done

-- | Monitor a process that becomes disconnected
testMonitorDisconnect :: TestTransport -> Bool -> Bool -> Assertion
testMonitorDisconnect TestTransport{..} mOrL un = do
  processAddr <- newEmptyMVar
  processAddr2 <- newEmptyMVar
  monitorSetup <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode $ expect
    addr2 <- forkProcess localNode $ return ()
    putMVar processAddr addr
    readMVar monitorSetup
    NT.closeEndPoint (localEndPoint localNode)
    putMVar processAddr2 addr2

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    theirAddr <- readMVar processAddr
    forkProcess localNode $ do
      lc <- liftIO $ readMVar processAddr2
      send lc ()
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedDisconnect (Just monitorSetup) done

  takeMVar done

-- | Test the math server (i.e., receiveWait)
testMath :: TestTransport -> Assertion
testMath TestTransport{..} = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode math
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    mathServer <- readMVar serverAddr

    runProcess localNode $ do
      pid <- getSelfPid
      send mathServer (Add pid 1 2)
      3 <- expect :: Process Double
      send mathServer (Divide pid 8 2)
      4 <- expect :: Process Double
      send mathServer (Divide pid 8 0)
      DivByZero <- expect
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Send first message (i.e. connect) to an already terminated process
-- (without monitoring); then send another message to a second process on
-- the same remote node (we're checking that the remote node did not die)
testSendToTerminated :: TestTransport -> Assertion
testSendToTerminated TestTransport{..} = do
  serverAddr1 <- newEmptyMVar
  serverAddr2 <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    terminated <- newEmptyMVar
    localNode <- newLocalNode testTransport initRemoteTable
    addr1 <- forkProcess localNode $ liftIO $ putMVar terminated ()
    addr2 <- forkProcess localNode $ ping
    readMVar terminated
    putMVar serverAddr1 addr1
    putMVar serverAddr2 addr2

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    server1 <- readMVar serverAddr1
    server2 <- readMVar serverAddr2
    runProcess localNode $ do
      pid <- getSelfPid
      send server1 "Hi"
      send server2 (Pong pid)
      Ping pid' <- expect
      True <- return $ pid' == server2
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test (non-zero) timeout
testTimeout :: TestTransport -> Assertion
testTimeout TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  runProcess localNode $ do
    Nothing <- receiveTimeout 1000000 [match (\(Add _ _ _) -> return ())]
    liftIO $ putMVar done ()

  takeMVar done

-- | Test zero timeout
testTimeout0 :: TestTransport -> Assertion
testTimeout0 TestTransport{..} = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  messagesSent <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    addr <- forkProcess localNode $ do
      liftIO $ readMVar messagesSent >> threadDelay 1000000
      -- Variation on the venerable ping server which uses a zero timeout
      -- Since we wait for all messages to be sent before doing this receive,
      -- we should nevertheless find the right message immediately
      Just partner <- receiveTimeout 0 [match (\(Pong partner) -> return partner)]
      self <- getSelfPid
      send partner (Ping self)
    putMVar serverAddr addr

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    server <- readMVar serverAddr
    runProcess localNode $ do
      pid <- getSelfPid
      -- Send a bunch of messages. A large number of messages that the server
      -- is not interested in, and then a single message that it wants
      replicateM_ 10000 $ send server "Irrelevant message"
      send server (Pong pid)
      liftIO $ putMVar messagesSent ()
      Ping _ <- expect
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test typed channels
testTypedChannels :: TestTransport -> Assertion
testTypedChannels TestTransport{..} = do
  serverChannel <- newEmptyMVar :: IO (MVar (SendPort (SendPort Bool, Int)))
  clientDone <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    forkProcess localNode $ do
      (serverSendPort, rport) <- newChan
      liftIO $ putMVar serverChannel serverSendPort
      (clientSendPort, i) <- receiveChan rport
      sendChan clientSendPort (even i)
    return ()

  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    serverSendPort <- readMVar serverChannel
    runProcess localNode $ do
      (clientSendPort, rport) <- newChan
      sendChan serverSendPort (clientSendPort, 5)
      False <- receiveChan rport
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test merging receive ports
testMergeChannels :: TestTransport -> Assertion
testMergeChannels TestTransport{..} = do
    localNode <- newLocalNode testTransport initRemoteTable
    testFlat localNode True          "aaabbbccc"
    testFlat localNode False         "abcabcabc"
    testNested localNode True True   "aaabbbcccdddeeefffggghhhiii"
    testNested localNode True False  "adgadgadgbehbehbehcficficfi"
    testNested localNode False True  "abcabcabcdefdefdefghighighi"
    testNested localNode False False "adgbehcfiadgbehcfiadgbehcfi"
    testBlocked localNode True
    testBlocked localNode False
  where
    -- Single layer of merging
    testFlat :: LocalNode -> Bool -> String -> IO ()
    testFlat localNode biased expected = do
      done <- newEmptyMVar
      forkProcess localNode $ do
        rs  <- mapM charChannel "abc"
        m   <- mergePorts biased rs
        xs  <- replicateM 9 $ receiveChan m
        True <- return $ xs == expected
        liftIO $ putMVar done ()
      takeMVar done

    -- Two layers of merging
    testNested :: LocalNode -> Bool -> Bool -> String -> IO ()
    testNested localNode biasedInner biasedOuter expected = do
      done <- newEmptyMVar
      forkProcess localNode $ do
        rss  <- mapM (mapM charChannel) ["abc", "def", "ghi"]
        ms   <- mapM (mergePorts biasedInner) rss
        m    <- mergePorts biasedOuter ms
        xs   <- replicateM (9 * 3) $ receiveChan m
        True <- return $ xs == expected
        liftIO $ putMVar done ()
      takeMVar done

    -- Test that if no messages are (immediately) available, the scheduler makes no difference
    testBlocked :: LocalNode -> Bool -> IO ()
    testBlocked localNode biased = do
      vs <- replicateM 3 newEmptyMVar
      done <- newEmptyMVar

      forkProcess localNode $ do
        [sa, sb, sc] <- liftIO $ mapM readMVar vs
        mapM_ ((>> liftIO (threadDelay 10000)) . uncurry sendChan)
          [ -- a, b, c
            (sa, 'a')
          , (sb, 'b')
          , (sc, 'c')
            -- a, c, b
          , (sa, 'a')
          , (sc, 'c')
          , (sb, 'b')
            -- b, a, c
          , (sb, 'b')
          , (sa, 'a')
          , (sc, 'c')
            -- b, c, a
          , (sb, 'b')
          , (sc, 'c')
          , (sa, 'a')
            -- c, a, b
          , (sc, 'c')
          , (sa, 'a')
          , (sb, 'b')
            -- c, b, a
          , (sc, 'c')
          , (sb, 'b')
          , (sa, 'a')
          ]

      forkProcess localNode $ do
        (ss, rs) <- unzip <$> replicateM 3 newChan
        liftIO $ mapM_ (uncurry putMVar) $ zip vs ss
        m  <- mergePorts biased rs
        xs <- replicateM (6 * 3) $ receiveChan m
        True <- return $ xs == "abcacbbacbcacabcba"
        liftIO $ putMVar done ()

      takeMVar done

    mergePorts :: Serializable a => Bool -> [ReceivePort a] -> Process (ReceivePort a)
    mergePorts True  = mergePortsBiased
    mergePorts False = mergePortsRR

    charChannel :: Char -> Process (ReceivePort Char)
    charChannel c = do
      (sport, rport) <- newChan
      replicateM_ 3 $ sendChan sport c
      liftIO $ threadDelay 10000 -- Make sure messages have been sent
      return rport

testTerminate :: TestTransport -> Assertion
testTerminate TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pid <- forkProcess localNode $ do
    liftIO $ threadDelay 100000
    terminate

  runProcess localNode $ do
    ref <- monitor pid
    ProcessMonitorNotification ref' pid' (DiedException ex) <- expect
    True <- return $ ref == ref' && pid == pid' && ex == show ProcessTerminationException
    liftIO $ putMVar done ()

  takeMVar done

testMonitorNode :: TestTransport -> Assertion
testMonitorNode TestTransport{..} = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  closeLocalNode node1

  runProcess node2 $ do
    ref <- monitorNode (localNodeId node1)
    NodeMonitorNotification ref' nid DiedDisconnect <- expect
    True <- return $ ref == ref' && nid == localNodeId node1
    liftIO $ putMVar done ()

  takeMVar done

testMonitorLiveNode :: TestTransport -> Assertion
testMonitorLiveNode TestTransport{..} = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport initRemoteTable
  ready <- newEmptyMVar
  readyr <- newEmptyMVar
  done <- newEmptyMVar

  p <- forkProcess node1 $ return ()
  forkProcess node2 $ do
    ref <- monitorNode (localNodeId node1)
    liftIO $ putMVar ready ()
    liftIO $ takeMVar readyr
    send p ()
    NodeMonitorNotification ref' nid _ <- expect
    True <- return $ ref == ref' && nid == localNodeId node1
    liftIO $ putMVar done ()

  takeMVar ready
  closeLocalNode node1
  putMVar readyr ()

  takeMVar done

testMonitorChannel :: TestTransport -> Assertion
testMonitorChannel TestTransport{..} = do
    [node1, node2] <- replicateM 2 $ newLocalNode testTransport initRemoteTable
    gotNotification <- newEmptyMVar

    pid <- forkProcess node1 $ do
      sport <- expect :: Process (SendPort ())
      ref <- monitorPort sport
      PortMonitorNotification ref' port' reason <- expect
      -- reason might be DiedUnknownId if the receive port is GCed before the
      -- monitor is established (TODO: not sure that this is reasonable)
      return $ ref' == ref && port' == sendPortId sport && (reason == DiedNormal || reason == DiedUnknownId)
      liftIO $ putMVar gotNotification ()

    runProcess node2 $ do
      (sport, _) <- newChan :: Process (SendPort (), ReceivePort ())
      send pid sport
      liftIO $ threadDelay 100000

    takeMVar gotNotification

testRegistry :: TestTransport -> Assertion
testRegistry TestTransport{..} = do
  node <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pingServer <- forkProcess node ping
  deadProcess <- forkProcess node (return ())

  runProcess node $ do
    register "ping" pingServer
    Just pid <- whereis "ping"
    True <- return $ pingServer == pid
    us <- getSelfPid
    nsend "ping" (Pong us)
    Ping pid' <- expect
    True <- return $ pingServer == pid'
    Left (ProcessRegistrationException "dead" Nothing)  <- try $ register "dead" deadProcess
    Left (ProcessRegistrationException "ping" (Just x)) <- try $ register "ping" deadProcess
    True <- return $ x == pingServer
    Left (ProcessRegistrationException "dead" Nothing) <- try $ unregister "dead"
    liftIO $ putMVar done ()

  takeMVar done

testRegistryRemoteProcess :: TestTransport -> Assertion
testRegistryRemoteProcess TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pingServer <- forkProcess node1 ping

  runProcess node2 $ do
    register "ping" pingServer
    Just pid <- whereis "ping"
    True <- return $ pingServer == pid
    us <- getSelfPid
    nsend "ping" (Pong us)
    Ping pid' <- expect
    True <- return $ pingServer == pid'
    liftIO $ putMVar done ()

  takeMVar done

testRemoteRegistry :: TestTransport -> Assertion
testRemoteRegistry TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pingServer <- forkProcess node1 ping
  deadProcess <- forkProcess node1 (return ())

  runProcess node2 $ do
    let nid1 = localNodeId node1
    registerRemoteAsync nid1 "ping" pingServer
    receiveWait [
       matchIf (\(RegisterReply label' _ (Just pid)) ->
                    "ping" == label' && pid == pingServer)
               (\(RegisterReply _ _ _) -> return ()) ]

    Just pid <- whereisRemote nid1 "ping"
    True <- return $ pingServer == pid
    us <- getSelfPid
    nsendRemote nid1 "ping" (Pong us)
    Ping pid' <- expect
    True <- return $ pingServer == pid'

    -- test that if process was not registered Nothing is returned
    -- in owner field.
    registerRemoteAsync nid1 "dead" deadProcess
    receiveWait [
       matchIf (\(RegisterReply label' False Nothing) -> "dead" == label')
               (\(RegisterReply _ _ _) -> return ()) ]
    registerRemoteAsync nid1 "ping" deadProcess
    receiveWait [
       matchIf (\(RegisterReply label' False (Just pid)) ->
                    "ping" == label' && pid == pingServer)
               (\(RegisterReply _ _ _) -> return ()) ]
    unregisterRemoteAsync nid1 "dead"
    receiveWait [
       matchIf (\(RegisterReply label' False Nothing) ->
                    "dead" == label' && pid == pingServer)
               (\(RegisterReply _ _ _) -> return ()) ]
    liftIO $ putMVar done ()

  takeMVar done

testRemoteRegistryRemoteProcess :: TestTransport -> Assertion
testRemoteRegistryRemoteProcess TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pingServer <- forkProcess node2 ping

  runProcess node2 $ do
    let nid1 = localNodeId node1
    registerRemoteAsync nid1 "ping" pingServer
    receiveWait [
       matchIf (\(RegisterReply label' _ _) -> "ping" == label')
               (\(RegisterReply _ _ _) -> return ()) ]
    Just pid <- whereisRemote nid1 "ping"
    True <- return $ pingServer == pid
    us <- getSelfPid
    nsendRemote nid1 "ping" (Pong us)
    Ping pid' <- expect
    True <- return $ pingServer == pid'
    liftIO $ putMVar done ()

  takeMVar done

testSpawnLocal :: TestTransport -> Assertion
testSpawnLocal TestTransport{..} = do
  node <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  runProcess node $ do
    us <- getSelfPid

    pid <- spawnLocal $ do
      sport <- expect
      sendChan sport (1234 :: Int)

    sport <- spawnChannelLocal $ \rport -> do
      (1234 :: Int) <- receiveChan rport
      send us ()

    send pid sport
    () <- expect
    liftIO $ putMVar done ()

  takeMVar done

testSpawnAsyncStrictness :: TestTransport -> Assertion
testSpawnAsyncStrictness TestTransport{..} = do
  node <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  runProcess node $ do
    here <-getSelfNode

    ev <- try $ spawnAsync here (error "boom")
    liftIO $ case ev of
      Right _ -> putMVar done (error "Exception didn't fire")
      Left (_::SomeException) -> putMVar done (return ())

  join $ takeMVar done

testReconnect :: TestTransport -> Assertion
testReconnect TestTransport{..} = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport initRemoteTable
  let nid1 = localNodeId node1
  processA <- newEmptyMVar
  [sendTestOk, registerTestOk] <- replicateM 2 newEmptyMVar

  forkProcess node1 $ do
    us <- getSelfPid
    liftIO $ putMVar processA us
    msg1 <- expect
    msg2 <- expect
    True <- return $ msg1 == "message 1" && msg2 == "message 3"
    liftIO $ putMVar sendTestOk ()

  forkProcess node2 $ do
    {-
     - Make sure there is no implicit reconnect on normal message sending
     -}

    them <- liftIO $ readMVar processA
    send them "message 1" >> liftIO (threadDelay 100000)

    -- Simulate network failure
    liftIO $ syncBreakConnection testBreakConnection node1 node2


    -- Should not arrive
    send them "message 2"

    -- Should arrive
    reconnect them
    send them "message 3"

    liftIO $ takeMVar sendTestOk

    {-
     - Test that there *is* implicit reconnect on node controller messages
     -}

    us <- getSelfPid
    registerRemoteAsync nid1 "a" us -- registerRemote is asynchronous
    receiveWait [
        matchIf (\(RegisterReply label' _ _) -> "a" == label')
                (\(RegisterReply _ _ _) -> return ()) ]

    Just _  <- whereisRemote nid1 "a"


    -- Simulate network failure
    liftIO $ syncBreakConnection testBreakConnection node1 node2

    -- This will happen due to implicit reconnect
    registerRemoteAsync nid1 "b" us
    receiveWait [
        matchIf (\(RegisterReply label' _ _) -> "b" == label')
                (\(RegisterReply _ _ _) -> return ()) ]

    -- Should happen
    registerRemoteAsync nid1 "c" us
    receiveWait [
        matchIf (\(RegisterReply label' _ _) -> "c" == label')
                (\(RegisterReply _ _ _) -> return ()) ]

    -- Check
    Nothing  <- whereisRemote nid1 "a"  -- this will fail because the name is removed when the node is disconnected
    Just _  <- whereisRemote nid1 "b"  -- this will suceed because the value is set after thereconnect
    Just _  <- whereisRemote nid1 "c"

    liftIO $ putMVar registerTestOk ()

  takeMVar registerTestOk

-- | Tests that unreliable messages arrive sorted even when there are connection
-- failures.
testUSend :: (ProcessId -> Int -> Process ())
          -> TestTransport -> Int -> Assertion
testUSend usendPrim TestTransport{..} numMessages = do
  [node1, node2] <- replicateM 2 $ newLocalNode testTransport initRemoteTable
  let nid1 = localNodeId node1
      nid2 = localNodeId node2
  processA <- newEmptyMVar
  usendTestOk <- newEmptyMVar

  forkProcess node1 $ flip catch (\e -> liftIO $ print (e :: SomeException) ) $ do
    us <- getSelfPid
    liftIO $ putMVar processA us
    them <- expect
    send them ()
    _ <- monitor them
    let -- Collects messages from 'them' until the sender dies.
        -- Disconnection notifications are ignored.
        receiveMessages :: Process [Int]
        receiveMessages = receiveWait
              [ match $ \mn -> case mn of
                  ProcessMonitorNotification _ _ DiedDisconnect -> do
                    monitor them
                    receiveMessages
                  _ -> return []
              , match $ \i -> fmap (i :) receiveMessages
              ]
    msgs <- receiveMessages
    let -- Checks that the input list is sorted.
        isSorted :: [Int] -> Bool
        isSorted (x : xs@(y : _)) = x <= y && isSorted xs
        isSorted _                = True
    -- The list can't be null since there are no failures after sending
    -- the last message.
    True <- return $ isSorted msgs && not (null msgs)
    liftIO $ putMVar usendTestOk ()

  forkProcess node2 $ do
    them <- liftIO $ readMVar processA
    getSelfPid >>= send them
    () <- expect
    forM_ [1..numMessages] $ \i -> do
      liftIO $ testBreakConnection (nodeAddress nid1) (nodeAddress nid2)
      usendPrim them i
      liftIO (threadDelay 30000)

  takeMVar usendTestOk

-- | Test 'matchAny'. This repeats the 'testMath' but with a proxy server
-- in between
testMatchAny :: TestTransport -> Assertion
testMatchAny TestTransport{..} = do
  proxyAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Math server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    mathServer <- forkProcess localNode math
    proxyServer <- forkProcess localNode $ forever $ do
      msg <- receiveWait [ matchAny return ]
      forward msg mathServer
    putMVar proxyAddr proxyServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    mathServer <- readMVar proxyAddr

    runProcess localNode $ do
      pid <- getSelfPid
      send mathServer (Add pid 1 2)
      3 <- expect :: Process Double
      send mathServer (Divide pid 8 2)
      4 <- expect :: Process Double
      send mathServer (Divide pid 8 0)
      DivByZero <- expect
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test 'matchAny'. This repeats the 'testMath' but with a proxy server
-- in between, however we block 'Divide' requests ....
testMatchAnyHandle :: TestTransport -> Assertion
testMatchAnyHandle TestTransport{..} = do
  proxyAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Math server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    mathServer <- forkProcess localNode math
    proxyServer <- forkProcess localNode $ forever $ do
        receiveWait [
            matchAny (maybeForward mathServer)
          ]
    putMVar proxyAddr proxyServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    mathServer <- readMVar proxyAddr

    runProcess localNode $ do
      pid <- getSelfPid
      send mathServer (Add pid 1 2)
      3 <- expect :: Process Double
      send mathServer (Divide pid 8 2)
      Nothing <- (expectTimeout 100000) :: Process (Maybe Double)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone
  where maybeForward :: ProcessId -> Message -> Process (Maybe ())
        maybeForward s msg =
            handleMessage msg (\m@(Add _ _ _) -> send s m)

testMatchAnyNoHandle :: TestTransport -> Assertion
testMatchAnyNoHandle TestTransport{..} = do
  addr <- newEmptyMVar
  clientDone <- newEmptyMVar
  serverDone <- newEmptyMVar

  -- Math server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    server <- forkProcess localNode $ forever $ do
        receiveWait [
          matchAnyIf
            -- the condition has type `Add -> Bool`
            (\(Add _ _ _) -> True)
            -- the match `AbstractMessage -> Process ()` will succeed!
            (\m -> do
              -- `String -> Process ()` does *not* match the input types however
              r <- (handleMessage m (\(_ :: String) -> die "NONSENSE" ))
              case r of
                Nothing -> return ()
                Just _  -> die "NONSENSE")
          ]
        -- we *must* have removed the message from our mailbox though!!!
        Nothing <- receiveTimeout 100000 [ match (\(Add _ _ _) -> return ()) ]
        liftIO $ putMVar serverDone ()
    putMVar addr server

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    server <- readMVar addr

    runProcess localNode $ do
      pid <- getSelfPid
      send server (Add pid 1 2)
      -- we only care about the client having sent a message, so we're done
      liftIO $ putMVar clientDone ()

  takeMVar clientDone
  takeMVar serverDone

-- | Test 'matchAnyIf'. We provide an /echo/ server, but it ignores requests
-- unless the text body @/= "bar"@ - this case should time out rather than
-- removing the message from the process mailbox.
testMatchAnyIf :: TestTransport -> Assertion
testMatchAnyIf TestTransport{..} = do
  echoAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- echo server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    echoServer <- forkProcess localNode $ forever $ do
        receiveWait [
            matchAnyIf (\(_ :: ProcessId, (s :: String)) -> s /= "bar")
                       tryHandleMessage
          ]
    putMVar echoAddr echoServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    server <- readMVar echoAddr

    runProcess localNode $ do
      pid <- getSelfPid
      send server (pid, "foo")
      "foo" <- expect
      send server (pid, "baz")
      "baz" <- expect
      send server (pid, "bar")
      Nothing <- (expectTimeout 100000) :: Process (Maybe Double)
      liftIO $ putMVar clientDone ()

  takeMVar clientDone
  where tryHandleMessage :: Message -> Process (Maybe ())
        tryHandleMessage msg =
          handleMessage msg (\(pid :: ProcessId, (m :: String))
                                  -> do { send pid m; return () })

testMatchMessageWithUnwrap :: TestTransport -> Assertion
testMatchMessageWithUnwrap TestTransport{..} = do
  echoAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

    -- echo server
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    echoServer <- forkProcess localNode $ forever $ do
        msg <- receiveWait [
            matchMessage (\(m :: Message) -> do
                            return m)
          ]
        unwrapped <- unwrapMessage msg :: Process (Maybe (ProcessId, Message))
        case unwrapped of
          (Just (p, msg')) -> forward msg' p
          Nothing -> die "unable to unwrap the message"
    putMVar echoAddr echoServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode testTransport initRemoteTable
    server <- readMVar echoAddr

    runProcess localNode $ do
      pid <- getSelfPid
      send server (pid, wrapMessage ("foo" :: String))
      "foo" <- expect
      send server (pid, wrapMessage ("baz" :: String))
      "baz" <- expect
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- Test 'receiveChanTimeout'
testReceiveChanTimeout :: TestTransport -> Assertion
testReceiveChanTimeout TestTransport{..} = do
  done <- newEmptyMVar
  sendPort <- newEmptyMVar

  forkTry $ do
    localNode <- newLocalNode testTransport initRemoteTable
    runProcess localNode $ do
      -- Create a typed channel
      (sp, rp) <- newChan :: Process (SendPort Bool, ReceivePort Bool)
      liftIO $ putMVar sendPort sp

      -- Wait for a message with a delay. No message arrives, we should get Nothing after 1 second
      Nothing <- receiveChanTimeout 1000000 rp

      -- Wait for a message with a delay again. Now a message arrives after 0.5 seconds
      Just True <- receiveChanTimeout 1000000 rp

      -- Wait for a message with zero timeout: non-blocking check. No message is available, we get Nothing
      Nothing <- receiveChanTimeout 0 rp

      -- Again, but now there is a message available
      liftIO $ threadDelay 1000000
      Just False <- receiveChanTimeout 0 rp

      liftIO $ putMVar done ()

  forkTry $ do
    localNode <- newLocalNode testTransport initRemoteTable
    runProcess localNode $ do
      sp <- liftIO $ readMVar sendPort

      liftIO $ threadDelay 1500000
      sendChan sp True

      liftIO $ threadDelay 500000
      sendChan sp False

  takeMVar done

-- | Test Functor, Applicative, Alternative and Monad instances for ReceiveChan
testReceiveChanFeatures :: TestTransport -> Assertion
testReceiveChanFeatures TestTransport{..} = do
  done <- newEmptyMVar

  forkTry $ do
    localNode <- newLocalNode testTransport initRemoteTable
    runProcess localNode $ do
      (spInt,  rpInt)  <- newChan :: Process (SendPort Int, ReceivePort Int)
      (spBool, rpBool) <- newChan :: Process (SendPort Bool, ReceivePort Bool)

      -- Test Functor instance

      sendChan spInt 2
      sendChan spBool False

      rp1 <- mergePortsBiased [even <$> rpInt, rpBool]

      True <- receiveChan rp1
      False <- receiveChan rp1

      -- Test Applicative instance

      sendChan spInt 3
      sendChan spInt 4

      let rp2 = pure (+) <*> rpInt <*> rpInt

      7 <- receiveChan rp2

      -- Test Alternative instance

      sendChan spInt 3
      sendChan spBool True

      let rp3 = (even <$> rpInt) <|> rpBool

      False <- receiveChan rp3
      True <- receiveChan rp3

      -- Test Monad instance

      sendChan spBool True
      sendChan spBool False
      sendChan spInt 5

      let rp4 :: ReceivePort Int
          rp4 = do b <- rpBool
                   if b
                     then rpInt
                     else return 7

      5 <- receiveChan rp4
      7 <- receiveChan rp4

      liftIO $ putMVar done ()

  takeMVar done

testKillLocal :: TestTransport -> Assertion
testKillLocal TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pid <- forkProcess localNode $ do
    liftIO $ threadDelay 1000000

  runProcess localNode $ do
    ref <- monitor pid
    us <- getSelfPid
    kill pid "TestKill"
    ProcessMonitorNotification ref' pid' (DiedException ex) <- expect
    True <- return $ ref == ref' && pid == pid' && ex == "killed-by=" ++ show us ++ ",reason=TestKill"
    liftIO $ putMVar done ()

  takeMVar done

testKillRemote :: TestTransport -> Assertion
testKillRemote TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  pid <- forkProcess node1 $ do
    liftIO $ threadDelay 1000000

  runProcess node2 $ do
    ref <- monitor pid
    us <- getSelfPid
    kill pid "TestKill"
    ProcessMonitorNotification ref' pid' (DiedException reason) <- expect
    True <- return $ ref == ref' && pid == pid' && reason == "killed-by=" ++ show us ++ ",reason=TestKill"
    liftIO $ putMVar done ()

  takeMVar done

testCatchesExit :: TestTransport -> Assertion
testCatchesExit TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
      (die ("foobar", 123 :: Int))
      `catchesExit` [
           (\_ m -> handleMessage m (\(_ :: String) -> return ()))
         , (\_ m -> handleMessage m (\(_ :: Maybe Int) -> return ()))
         , (\_ m -> handleMessage m (\(_ :: String, _ :: Int)
                    -> (liftIO $ putMVar done ()) >> return ()))
         ]

  takeMVar done

testHandleMessageIf :: TestTransport -> Assertion
testHandleMessageIf TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar
  _ <- forkProcess localNode $ do
    self <- getSelfPid
    send self (5 :: Integer, 10 :: Integer)
    msg <- receiveWait [ matchMessage return ]
    Nothing <- handleMessageIf msg (\() -> True) (\() -> die $ "whoops")
    handleMessageIf msg (\(x :: Integer, y :: Integer) -> x == 5 && y == 10)
                        (\input -> liftIO $ putMVar done input)
    return ()

  result <- takeMVar done
  expectThat result $ equalTo (5, 10)

testCatches :: TestTransport -> Assertion
testCatches TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
    node <- getSelfNode
    (liftIO $ throwIO (ProcessLinkException (nullProcessId node) DiedNormal))
    `catches` [
        Handler (\(ProcessLinkException _ _) -> liftIO $ putMVar done ())
      ]

  takeMVar done

testMaskRestoreScope :: TestTransport -> Assertion
testMaskRestoreScope TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  parentPid <- newEmptyMVar :: IO (MVar ProcessId)
  spawnedPid <- newEmptyMVar :: IO (MVar ProcessId)

  void $ runProcess localNode $ mask $ \unmask -> do
    getSelfPid >>= liftIO . putMVar parentPid
    void $ spawnLocal $ unmask (getSelfPid >>= liftIO . putMVar spawnedPid)

  parent <- liftIO $ takeMVar parentPid
  child <- liftIO $ takeMVar spawnedPid
  expectThat parent $ isNot $ equalTo child

testDie :: TestTransport -> Assertion
testDie TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
      (die ("foobar", 123 :: Int))
      `catchExit` \_from reason -> do
        -- TODO: should verify that 'from' has the right value
        True <- return $ reason == ("foobar", 123 :: Int)
        liftIO $ putMVar done ()

  takeMVar done

testPrettyExit :: TestTransport -> Assertion
testPrettyExit TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
      (die "timeout")
      `catch` \ex@(ProcessExitException from _) ->
        let expected = "exit-from=" ++ (show from)
        in do
          True <- return $ (show ex) == expected
          liftIO $ putMVar done ()

  takeMVar done

testExitLocal :: TestTransport -> Assertion
testExitLocal TestTransport{..} = do
  localNode <- newLocalNode testTransport initRemoteTable
  supervisedDone <- newEmptyMVar
  supervisorDone <- newEmptyMVar
  -- XXX: we guarantee that exception handler will be set up
  -- regardless if forkProcess preserve masking state or not.
  handlerSetUp <- newEmptyMVar

  pid <- forkProcess localNode $ do
    (liftIO (putMVar handlerSetUp ()) >> expect) `catchExit` \_from reason -> do
        -- TODO: should verify that 'from' has the right value
        True <- return $ reason == "TestExit"
        liftIO $ putMVar supervisedDone ()

  runProcess localNode $ do
    liftIO $ takeMVar handlerSetUp
    ref <- monitor pid
    exit pid "TestExit"
    -- This time the client catches the exception, so it dies normally
    ProcessMonitorNotification ref' pid' DiedNormal <- expect
    True <- return $ ref == ref' && pid == pid'
    liftIO $ putMVar supervisorDone ()

  takeMVar supervisedDone
  takeMVar supervisorDone

testExitRemote :: TestTransport -> Assertion
testExitRemote TestTransport{..} = do
  node1 <- newLocalNode testTransport initRemoteTable
  node2 <- newLocalNode testTransport initRemoteTable
  supervisedDone <- newEmptyMVar
  supervisorDone <- newEmptyMVar

  pid <- forkProcess node1 $ do
    (receiveWait [] :: Process ()) -- block forever
      `catchExit` \_from reason -> do
        -- TODO: should verify that 'from' has the right value
        True <- return $ reason == "TestExit"
        liftIO $ putMVar supervisedDone ()

  runProcess node2 $ do
    ref <- monitor pid
    exit pid "TestExit"
    ProcessMonitorNotification ref' pid' DiedNormal <- expect
    True <- return $ ref == ref' && pid == pid'
    liftIO $ putMVar supervisorDone ()

  takeMVar supervisedDone
  takeMVar supervisorDone

testUnsafeSend :: TestTransport -> Assertion
testUnsafeSend TestTransport{..} = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  localNode <- newLocalNode testTransport initRemoteTable
  void $ forkProcess localNode $ do
    self <- getSelfPid
    liftIO $ putMVar serverAddr self
    clientAddr <- expect
    unsafeSend clientAddr ()

  void $ forkProcess localNode $ do
    serverPid <- liftIO $ takeMVar serverAddr
    getSelfPid >>= unsafeSend serverPid
    () <- expect
    liftIO $ putMVar clientDone ()

  takeMVar clientDone

testUnsafeNSend :: TestTransport -> Assertion
testUnsafeNSend TestTransport{..} = do
  clientDone <- newEmptyMVar

  localNode <- newLocalNode testTransport initRemoteTable

  pid <- forkProcess localNode $ do
    () <- expect
    liftIO $ putMVar clientDone ()

  void $ runProcess localNode $ do
    register "foobar" pid
    unsafeNSend "foobar" ()

  takeMVar clientDone

testUnsafeSendChan :: TestTransport -> Assertion
testUnsafeSendChan TestTransport{..} = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  localNode <- newLocalNode testTransport initRemoteTable
  void $ forkProcess localNode $ do
    self <- getSelfPid
    liftIO $ putMVar serverAddr self
    sp <- expect
    unsafeSendChan sp ()

  void $ forkProcess localNode $ do
    serverPid <- liftIO $ takeMVar serverAddr
    (sp, rp) <- newChan
    unsafeSend serverPid sp
    () <- receiveChan rp
    liftIO $ putMVar clientDone ()

  takeMVar clientDone

testCallLocal :: TestTransport -> Assertion
testCallLocal TestTransport{..} = do
  node <- newLocalNode testTransport initRemoteTable

  -- Testing that (/=) <$> getSelfPid <*> callLocal getSelfPid.
  result <- newEmptyMVar
  runProcess node $ do
    r <- (/=) <$> getSelfPid <*> callLocal getSelfPid
    liftIO $ putMVar result r
  True <- takeMVar result
  return ()

  -- Testing that when callLocal is interrupted, the worker is interrupted.
  ibox <- newIORef False
  runProcess node $ do
    keeper <- getSelfPid
    spawnLocal $ do
        caller <- getSelfPid
        send keeper caller
        onException
          (callLocal $ do
                onException (do send keeper caller
                                expect)
                            (do liftIO $ writeIORef ibox True))
          (send keeper ())
    caller <- expect
    exit caller "test"
    ()     <- expect
    return ()
  True <- readIORef ibox
  return ()

  -- Testing that when the worker raises an exception, the exception is propagated to the parent.
  ibox2 <- newIORef False
  runProcess node $ do
    r <- try (callLocal $ error "e" >> return ())
    liftIO $ writeIORef ibox2 $ case r of
      Left (ErrorCall "e") -> True
      _ -> False
  True <- readIORef ibox
  return ()

  -- Test that caller waits for the worker in correct situation
  ibox3 <- newIORef False
  result3 <- newEmptyMVar
  runProcess node $ do
    keeper <- getSelfPid
    spawnLocal $ do
        callLocal $
            (do us <- getSelfPid
                send keeper us
                () <- expect
                liftIO yield)
            `finally` (liftIO $ writeIORef ibox3 True)
        liftIO $ putMVar result3 =<< readIORef ibox3
    worker <- expect
    send worker ()
  True <- takeMVar result3
  return ()

  -- Test that caller waits for the worker in case when caller gets an exception
  ibox4 <- newIORef False
  result4 <- newEmptyMVar
  runProcess node $ do
    keeper <- getSelfPid
    spawnLocal $ do
        caller <- getSelfPid
        callLocal
            ((do send keeper caller
                 expect)
               `finally` (liftIO $ writeIORef ibox4 True))
            `finally` (liftIO $ putMVar result4 =<< readIORef ibox4)
    caller <- expect
    exit caller "hi!"
  True <- takeMVar result4
  return ()
  -- XXX: Testing that when mask_ $ callLocal p runs p in masked state.





tests :: TestTransport -> IO [Test]
tests testtrans = return [
     testGroup "Basic features" [
        testCase "Ping"                (testPing                testtrans)
      , testCase "Math"                (testMath                testtrans)
      , testCase "Timeout"             (testTimeout             testtrans)
      , testCase "Timeout0"            (testTimeout0            testtrans)
      , testCase "SendToTerminated"    (testSendToTerminated    testtrans)
      , testCase "TypedChannnels"      (testTypedChannels       testtrans)
      , testCase "MergeChannels"       (testMergeChannels       testtrans)
      , testCase "Terminate"           (testTerminate           testtrans)
      , testCase "Registry"            (testRegistry            testtrans)
      , testCase "RegistryRemoteProcess" (testRegistryRemoteProcess      testtrans)
      , testCase "RemoteRegistry"      (testRemoteRegistry      testtrans)
      , testCase "RemoteRegistryRemoteProcess" (testRemoteRegistryRemoteProcess      testtrans)
      , testCase "SpawnLocal"          (testSpawnLocal          testtrans)
      , testCase "SpawnAsyncStrictness" (testSpawnAsyncStrictness testtrans)
      , testCase "HandleMessageIf"     (testHandleMessageIf     testtrans)
      , testCase "MatchAny"            (testMatchAny            testtrans)
      , testCase "MatchAnyHandle"      (testMatchAnyHandle      testtrans)
      , testCase "MatchAnyNoHandle"    (testMatchAnyNoHandle    testtrans)
      , testCase "MatchAnyIf"          (testMatchAnyIf          testtrans)
      , testCase "MatchMessageUnwrap"  (testMatchMessageWithUnwrap testtrans)
      , testCase "ReceiveChanTimeout"  (testReceiveChanTimeout  testtrans)
      , testCase "ReceiveChanFeatures" (testReceiveChanFeatures testtrans)
      , testCase "KillLocal"           (testKillLocal           testtrans)
      , testCase "KillRemote"          (testKillRemote          testtrans)
      , testCase "Die"                 (testDie                 testtrans)
      , testCase "PrettyExit"          (testPrettyExit          testtrans)
      , testCase "CatchesExit"         (testCatchesExit         testtrans)
      , testCase "Catches"             (testCatches             testtrans)
      , testCase "MaskRestoreScope"    (testMaskRestoreScope    testtrans)
      , testCase "ExitLocal"           (testExitLocal           testtrans)
      , testCase "ExitRemote"          (testExitRemote          testtrans)
      , testCase "TextCallLocal"       (testCallLocal           testtrans)
      -- Unsafe Primitives
      , testCase "TestUnsafeSend"      (testUnsafeSend          testtrans)
      , testCase "TestUnsafeNSend"     (testUnsafeNSend         testtrans)
      , testCase "TestUnsafeSendChan"  (testUnsafeSendChan      testtrans)
      -- usend
      , testCase "USend"               (testUSend usend         testtrans 50)
      , testCase "UForward"
                 (testUSend (\p m -> uforward (createUnencodedMessage m) p)
                            testtrans 50
                 )
      ]
    , testGroup "Monitoring and Linking" [
      -- Monitoring processes
      --
      -- The "missing" combinations in the list below don't make much sense, as
      -- we cannot guarantee that the monitor reply or link exception will not
      -- happen before the unmonitor or unlink
      testCase "MonitorUnreachable"           (testMonitorUnreachable         testtrans True  False)
    , testCase "MonitorNormalTermination"     (testMonitorNormalTermination   testtrans True  False)
    , testCase "MonitorAbnormalTermination"   (testMonitorAbnormalTermination testtrans True  False)
    , testCase "MonitorLocalDeadProcess"      (testMonitorLocalDeadProcess    testtrans True  False)
    , testCase "MonitorRemoteDeadProcess"     (testMonitorRemoteDeadProcess   testtrans True  False)
    , testCase "MonitorDisconnect"            (testMonitorDisconnect          testtrans True  False)
    , testCase "LinkUnreachable"              (testMonitorUnreachable         testtrans False False)
    , testCase "LinkNormalTermination"        (testMonitorNormalTermination   testtrans False False)
    , testCase "LinkAbnormalTermination"      (testMonitorAbnormalTermination testtrans False False)
    , testCase "LinkLocalDeadProcess"         (testMonitorLocalDeadProcess    testtrans False False)
    , testCase "LinkRemoteDeadProcess"        (testMonitorRemoteDeadProcess   testtrans False False)
    , testCase "LinkDisconnect"               (testMonitorDisconnect          testtrans False False)
    , testCase "UnmonitorNormalTermination"   (testMonitorNormalTermination   testtrans True  True)
    , testCase "UnmonitorAbnormalTermination" (testMonitorAbnormalTermination testtrans True  True)
    , testCase "UnmonitorDisconnect"          (testMonitorDisconnect          testtrans True  True)
    , testCase "UnlinkNormalTermination"      (testMonitorNormalTermination   testtrans False True)
    , testCase "UnlinkAbnormalTermination"    (testMonitorAbnormalTermination testtrans False True)
    , testCase "UnlinkDisconnect"             (testMonitorDisconnect          testtrans False True)
      -- Monitoring nodes and channels
    , testCase "MonitorNode"                  (testMonitorNode                testtrans)
    , testCase "MonitorLiveNode"              (testMonitorLiveNode            testtrans)
    , testCase "MonitorChannel"               (testMonitorChannel             testtrans)
      -- Reconnect
    , testCase "Reconnect"                    (testReconnect                  testtrans)
    ]
  ]

syncBreakConnection :: (NT.EndPointAddress -> NT.EndPointAddress -> IO ()) -> LocalNode -> LocalNode -> IO ()
syncBreakConnection breakConnection nid0 nid1 = do
  m <- newEmptyMVar
  _ <- forkProcess nid1 $ getSelfPid >>= liftIO . putMVar m
  runProcess nid0 $ do
    them <- liftIO $ takeMVar m
    pinger <- spawnLocal $ forever $ send them ()
    _ <- monitorNode (localNodeId nid1)
    liftIO $ breakConnection (nodeAddress $ localNodeId nid0)
                             (nodeAddress $ localNodeId nid1)
    NodeMonitorNotification _ _ _ <- expect
    kill pinger "finished"
    return ()
