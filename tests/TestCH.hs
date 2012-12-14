module Main where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Data.Foldable (forM_)
import Control.Concurrent (forkIO, threadDelay, myThreadId, throwTo, ThreadId)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , readMVar
  )
import Control.Monad (replicateM_, replicateM, forever)
import Control.Exception (SomeException, throwIO)
import qualified Control.Exception as Ex (catch)
import Control.Applicative ((<$>), (<*>), pure, (<|>))
import qualified Network.Transport as NT (Transport, closeEndPoint)
import Network.Socket (sClose)
import Network.Transport.TCP
  ( createTransportExposeInternals
  , TransportInternals(socketBetween)
  , defaultTCPParameters
  )
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
  ( NodeId(nodeAddress)
  , LocalNode(localEndPoint)
  , ProcessExitException(..)
  , nullProcessId
  )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (Serializable)

import Test.HUnit (Assertion)
import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)

newtype Ping = Ping ProcessId
  deriving (Typeable, Binary, Show)

newtype Pong = Pong ProcessId
  deriving (Typeable, Binary, Show)

--------------------------------------------------------------------------------
-- Supporting definitions                                                     --
--------------------------------------------------------------------------------

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
              -> ProcessId       -- Process to monitor/link to
              -> Maybe (MVar ()) -- MVar to signal on once the monitor has been set up
              -> Process (Maybe MonitorRef)
monitorOrLink mOrL pid mSignal = do
  result <- if mOrL then Just <$> monitor pid
                    else link pid >> return Nothing
  -- Monitor is asynchronous, which usually does not matter but if we want a
  -- *specific* signal then it does. Therefore we wait an arbitrary delay and
  -- hope that this means the monitor has been set up
  forM_ mSignal $ \signal -> liftIO . forkIO $ threadDelay 100000 >> putMVar signal ()
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
testPing :: NT.Transport -> Assertion
testPing transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
testMonitorUnreachable :: NT.Transport -> Bool -> Bool -> Assertion
testMonitorUnreachable transport mOrL un = do
  deadProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000
    closeLocalNode localNode
    putMVar deadProcess addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar deadProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un DiedDisconnect Nothing done

  takeMVar done

-- | Monitor a process which terminates normally
testMonitorNormalTermination :: NT.Transport -> Bool -> Bool -> Assertion
testMonitorNormalTermination transport mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode $
      liftIO $ readMVar monitorSetup
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un DiedNormal (Just monitorSetup) done

  takeMVar done

-- | Monitor a process which terminates abnormally
testMonitorAbnormalTermination :: NT.Transport -> Bool -> Bool -> Assertion
testMonitorAbnormalTermination transport mOrL un = do
  monitorSetup <- newEmptyMVar
  monitoredProcess <- newEmptyMVar
  done <- newEmptyMVar

  let err = userError "Abnormal termination"

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ do
      readMVar monitorSetup
      throwIO err
    putMVar monitoredProcess addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar monitoredProcess
    runProcess localNode $
      monitorTestProcess theirAddr mOrL un (DiedException (show err)) (Just monitorSetup) done

  takeMVar done

-- | Monitor a local process that is already dead
testMonitorLocalDeadProcess :: NT.Transport -> Bool -> Bool -> Assertion
testMonitorLocalDeadProcess transport mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  localNode <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  forkIO $ do
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedUnknownId Nothing done

  takeMVar done

-- | Monitor a remote process that is already dead
testMonitorRemoteDeadProcess :: NT.Transport -> Bool -> Bool -> Assertion
testMonitorRemoteDeadProcess transport mOrL un = do
  processDead <- newEmptyMVar
  processAddr <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ putMVar processDead ()
    putMVar processAddr addr

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar processAddr
    readMVar processDead
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedUnknownId Nothing done

  takeMVar done

-- | Monitor a process that becomes disconnected
testMonitorDisconnect :: NT.Transport -> Bool -> Bool -> Assertion
testMonitorDisconnect transport mOrL un = do
  processAddr <- newEmptyMVar
  monitorSetup <- newEmptyMVar
  done <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode . liftIO $ threadDelay 1000000
    putMVar processAddr addr
    readMVar monitorSetup
    NT.closeEndPoint (localEndPoint localNode)

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    theirAddr <- readMVar processAddr
    runProcess localNode $ do
      monitorTestProcess theirAddr mOrL un DiedDisconnect (Just monitorSetup) done

  takeMVar done

-- | Test the math server (i.e., receiveWait)
testMath :: NT.Transport -> Assertion
testMath transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode math
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
testSendToTerminated :: NT.Transport -> Assertion
testSendToTerminated transport = do
  serverAddr1 <- newEmptyMVar
  serverAddr2 <- newEmptyMVar
  clientDone <- newEmptyMVar

  forkIO $ do
    terminated <- newEmptyMVar
    localNode <- newLocalNode transport initRemoteTable
    addr1 <- forkProcess localNode $ liftIO $ putMVar terminated ()
    addr2 <- forkProcess localNode $ ping
    readMVar terminated
    putMVar serverAddr1 addr1
    putMVar serverAddr2 addr2

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
testTimeout :: NT.Transport -> Assertion
testTimeout transport = do
  localNode <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  runProcess localNode $ do
    Nothing <- receiveTimeout 1000000 [match (\(Add _ _ _) -> return ())]
    liftIO $ putMVar done ()

  takeMVar done

-- | Test zero timeout
testTimeout0 :: NT.Transport -> Assertion
testTimeout0 transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  messagesSent <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
    localNode <- newLocalNode transport initRemoteTable
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
testTypedChannels :: NT.Transport -> Assertion
testTypedChannels transport = do
  serverChannel <- newEmptyMVar :: IO (MVar (SendPort (SendPort Bool, Int)))
  clientDone <- newEmptyMVar

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    forkProcess localNode $ do
      (serverSendPort, rport) <- newChan
      liftIO $ putMVar serverChannel serverSendPort
      (clientSendPort, i) <- receiveChan rport
      sendChan clientSendPort (even i)
    return ()

  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    serverSendPort <- readMVar serverChannel
    runProcess localNode $ do
      (clientSendPort, rport) <- newChan
      sendChan serverSendPort (clientSendPort, 5)
      False <- receiveChan rport
      liftIO $ putMVar clientDone ()

  takeMVar clientDone

-- | Test merging receive ports
testMergeChannels :: NT.Transport -> Assertion
testMergeChannels transport = do
    localNode <- newLocalNode transport initRemoteTable
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

testTerminate :: NT.Transport -> Assertion
testTerminate transport = do
  localNode <- newLocalNode transport initRemoteTable
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

testMonitorNode :: NT.Transport -> Assertion
testMonitorNode transport = do
  [node1, node2] <- replicateM 2 $ newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  closeLocalNode node1

  runProcess node2 $ do
    ref <- monitorNode (localNodeId node1)
    NodeMonitorNotification ref' nid DiedDisconnect <- expect
    True <- return $ ref == ref' && nid == localNodeId node1
    liftIO $ putMVar done ()

  takeMVar done

testMonitorChannel :: NT.Transport -> Assertion
testMonitorChannel transport = do
    [node1, node2] <- replicateM 2 $ newLocalNode transport initRemoteTable
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

testRegistry :: NT.Transport -> Assertion
testRegistry transport = do
  node <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  pingServer <- forkProcess node ping

  runProcess node $ do
    register "ping" pingServer
    Just pid <- whereis "ping"
    True <- return $ pingServer == pid
    us <- getSelfPid
    nsend "ping" (Pong us)
    Ping pid' <- expect
    True <- return $ pingServer == pid'
    liftIO $ putMVar done ()

  takeMVar done

testRemoteRegistry :: NT.Transport -> Assertion
testRemoteRegistry transport = do
  node1 <- newLocalNode transport initRemoteTable
  node2 <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  pingServer <- forkProcess node1 ping

  runProcess node2 $ do
    let nid1 = localNodeId node1
    registerRemoteAsync nid1 "ping" pingServer
    receiveWait [
       matchIf (\(RegisterReply label' _) -> "ping" == label')
               (\(RegisterReply _ _) -> return ()) ]

    Just pid <- whereisRemote nid1 "ping"
    True <- return $ pingServer == pid
    us <- getSelfPid
    nsendRemote nid1 "ping" (Pong us)
    Ping pid' <- expect
    True <- return $ pingServer == pid'
    liftIO $ putMVar done ()

  takeMVar done

testSpawnLocal :: NT.Transport -> Assertion
testSpawnLocal transport = do
  node <- newLocalNode transport initRemoteTable
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

testReconnect :: NT.Transport -> TransportInternals -> Assertion
testReconnect transport transportInternals = do
  [node1, node2] <- replicateM 2 $ newLocalNode transport initRemoteTable
  let nid1 = localNodeId node1
      nid2 = localNodeId node2
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
    liftIO $ do
      sock <- socketBetween transportInternals (nodeAddress nid1) (nodeAddress nid2)
      sClose sock
      threadDelay 10000

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
        matchIf (\(RegisterReply label' _) -> "a" == label')
                (\(RegisterReply _ _) -> return ()) ]

    Just _  <- whereisRemote nid1 "a"


    -- Simulate network failure
    liftIO $ do
      sock <- socketBetween transportInternals (nodeAddress nid1) (nodeAddress nid2)
      sClose sock
      threadDelay 10000

    -- This will happen due to implicit reconnect
    registerRemoteAsync nid1 "b" us
    receiveWait [
        matchIf (\(RegisterReply label' _) -> "b" == label')
                (\(RegisterReply _ _) -> return ()) ]

    -- Should happen
    registerRemoteAsync nid1 "c" us
    receiveWait [
        matchIf (\(RegisterReply label' _) -> "c" == label')
                (\(RegisterReply _ _) -> return ()) ]

    -- Check
    Nothing  <- whereisRemote nid1 "a"  -- this will fail because the name is removed when the node is disconnected
    Just _  <- whereisRemote nid1 "b"  -- this will suceed because the value is set after thereconnect
    Just _  <- whereisRemote nid1 "c"

    liftIO $ putMVar registerTestOk ()

  takeMVar registerTestOk

-- | Test 'matchAny'. This repeats the 'testMath' but with a proxy server
-- in between
testMatchAny :: NT.Transport -> Assertion
testMatchAny transport = do
  proxyAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Math server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    mathServer <- forkProcess localNode math
    proxyServer <- forkProcess localNode $ forever $ do
      msg <- receiveWait [ matchAny return ]
      forward msg mathServer
    putMVar proxyAddr proxyServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
testMatchAnyHandle :: NT.Transport -> Assertion
testMatchAnyHandle transport = do
  proxyAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Math server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    mathServer <- forkProcess localNode math
    proxyServer <- forkProcess localNode $ forever $ do
        receiveWait [
            matchAny (maybeForward mathServer)
          ]
    putMVar proxyAddr proxyServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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

testMatchAnyNoHandle :: NT.Transport -> Assertion
testMatchAnyNoHandle transport = do
  addr <- newEmptyMVar
  clientDone <- newEmptyMVar
  serverDone <- newEmptyMVar

  -- Math server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
    localNode <- newLocalNode transport initRemoteTable
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
testMatchAnyIf :: NT.Transport -> Assertion
testMatchAnyIf transport = do
  echoAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- echo server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    echoServer <- forkProcess localNode $ forever $ do
        receiveWait [
            matchAnyIf (\(_ :: ProcessId, (s :: String)) -> s /= "bar")
                       tryHandleMessage
          ]
    putMVar echoAddr echoServer

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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

testMatchMessageWithUnwrap :: NT.Transport -> Assertion
testMatchMessageWithUnwrap transport = do
  echoAddr <- newEmptyMVar
  clientDone <- newEmptyMVar
  
    -- echo server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
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
    localNode <- newLocalNode transport initRemoteTable
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
testReceiveChanTimeout :: NT.Transport -> Assertion
testReceiveChanTimeout transport = do
  done <- newEmptyMVar
  sendPort <- newEmptyMVar

  forkTry $ do
    localNode <- newLocalNode transport initRemoteTable
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
    localNode <- newLocalNode transport initRemoteTable
    runProcess localNode $ do
      sp <- liftIO $ readMVar sendPort

      liftIO $ threadDelay 1500000
      sendChan sp True

      liftIO $ threadDelay 500000
      sendChan sp False

  takeMVar done

-- | Test Functor, Applicative, Alternative and Monad instances for ReceiveChan
testReceiveChanFeatures :: NT.Transport -> Assertion
testReceiveChanFeatures transport = do
  done <- newEmptyMVar

  forkTry $ do
    localNode <- newLocalNode transport initRemoteTable
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

testKillLocal :: NT.Transport -> Assertion
testKillLocal transport = do
  localNode <- newLocalNode transport initRemoteTable
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

testKillRemote :: NT.Transport -> Assertion
testKillRemote transport = do
  node1 <- newLocalNode transport initRemoteTable
  node2 <- newLocalNode transport initRemoteTable
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

testCatchesExit :: NT.Transport -> Assertion
testCatchesExit transport = do
  localNode <- newLocalNode transport initRemoteTable
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

testCatches :: NT.Transport -> Assertion
testCatches transport = do
  localNode <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
    node <- getSelfNode
    (liftIO $ throwIO (ProcessLinkException (nullProcessId node) DiedNormal))
    `catches` [
        Handler (\(ProcessLinkException _ _) -> liftIO $ putMVar done ())
      ]

  takeMVar done

testDie :: NT.Transport -> Assertion
testDie transport = do
  localNode <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
      (die ("foobar", 123 :: Int))
      `catchExit` \_from reason -> do
        -- TODO: should verify that 'from' has the right value
        True <- return $ reason == ("foobar", 123 :: Int)
        liftIO $ putMVar done ()

  takeMVar done

testPrettyExit :: NT.Transport -> Assertion
testPrettyExit transport = do
  localNode <- newLocalNode transport initRemoteTable
  done <- newEmptyMVar

  _ <- forkProcess localNode $ do
      (die "timeout")
      `catch` \ex@(ProcessExitException from _) ->
        let expected = "exit-from=" ++ (show from)
        in do
          True <- return $ (show ex) == expected
          liftIO $ putMVar done ()

  takeMVar done

testExitLocal :: NT.Transport -> Assertion
testExitLocal transport = do
  localNode <- newLocalNode transport initRemoteTable
  supervisedDone <- newEmptyMVar
  supervisorDone <- newEmptyMVar

  pid <- forkProcess localNode $ do
    (liftIO $ threadDelay 100000)
      `catchExit` \_from reason -> do
        -- TODO: should verify that 'from' has the right value
        True <- return $ reason == "TestExit"
        liftIO $ putMVar supervisedDone ()

  runProcess localNode $ do
    ref <- monitor pid
    exit pid "TestExit"
    -- This time the client catches the exception, so it dies normally
    ProcessMonitorNotification ref' pid' DiedNormal <- expect
    True <- return $ ref == ref' && pid == pid'
    liftIO $ putMVar supervisorDone ()

  takeMVar supervisedDone
  takeMVar supervisorDone

testExitRemote :: NT.Transport -> Assertion
testExitRemote transport = do
  node1 <- newLocalNode transport initRemoteTable
  node2 <- newLocalNode transport initRemoteTable
  supervisedDone <- newEmptyMVar
  supervisorDone <- newEmptyMVar

  pid <- forkProcess node1 $ do
    (liftIO $ threadDelay 100000)
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

tests :: (NT.Transport, TransportInternals)  -> [Test]
tests (transport, transportInternals) = [
    testGroup "Basic features" [
        testCase "Ping"                (testPing                transport)
      , testCase "Math"                (testMath                transport)
      , testCase "Timeout"             (testTimeout             transport)
      , testCase "Timeout0"            (testTimeout0            transport)
      , testCase "SendToTerminated"    (testSendToTerminated    transport)
      , testCase "TypedChannnels"      (testTypedChannels       transport)
      , testCase "MergeChannels"       (testMergeChannels       transport)
      , testCase "Terminate"           (testTerminate           transport)
      , testCase "Registry"            (testRegistry            transport)
      , testCase "RemoteRegistry"      (testRemoteRegistry      transport)
      , testCase "SpawnLocal"          (testSpawnLocal          transport)
      , testCase "MatchAny"            (testMatchAny            transport)
      , testCase "MatchAnyHandle"      (testMatchAnyHandle      transport)
      , testCase "MatchAnyNoHandle"    (testMatchAnyNoHandle    transport)
      , testCase "MatchAnyIf"          (testMatchAnyIf          transport)
      , testCase "MatchMessageUnwrap"  (testMatchMessageWithUnwrap transport)
      , testCase "ReceiveChanTimeout"  (testReceiveChanTimeout  transport)
      , testCase "ReceiveChanFeatures" (testReceiveChanFeatures transport)
      , testCase "KillLocal"           (testKillLocal           transport)
      , testCase "KillRemote"          (testKillRemote          transport)
      , testCase "Die"                 (testDie                 transport)
      , testCase "PrettyExit"          (testPrettyExit          transport)
      , testCase "CatchesExit"         (testCatchesExit         transport)
      , testCase "Catches"             (testCatches             transport)
      , testCase "ExitLocal"           (testExitLocal           transport)
      , testCase "ExitRemote"          (testExitRemote          transport)
      ]
  , testGroup "Monitoring and Linking" [
      -- Monitoring processes
      --
      -- The "missing" combinations in the list below don't make much sense, as
      -- we cannot guarantee that the monitor reply or link exception will not
      -- happen before the unmonitor or unlink
      testCase "MonitorUnreachable"           (testMonitorUnreachable         transport True  False)
    , testCase "MonitorNormalTermination"     (testMonitorNormalTermination   transport True  False)
    , testCase "MonitorAbnormalTermination"   (testMonitorAbnormalTermination transport True  False)
    , testCase "MonitorLocalDeadProcess"      (testMonitorLocalDeadProcess    transport True  False)
    , testCase "MonitorRemoteDeadProcess"     (testMonitorRemoteDeadProcess   transport True  False)
    , testCase "MonitorDisconnect"            (testMonitorDisconnect          transport True  False)
    , testCase "LinkUnreachable"              (testMonitorUnreachable         transport False False)
    , testCase "LinkNormalTermination"        (testMonitorNormalTermination   transport False False)
    , testCase "LinkAbnormalTermination"      (testMonitorAbnormalTermination transport False False)
    , testCase "LinkLocalDeadProcess"         (testMonitorLocalDeadProcess    transport False False)
    , testCase "LinkRemoteDeadProcess"        (testMonitorRemoteDeadProcess   transport False False)
    , testCase "LinkDisconnect"               (testMonitorDisconnect          transport False False)
    , testCase "UnmonitorNormalTermination"   (testMonitorNormalTermination   transport True  True)
    , testCase "UnmonitorAbnormalTermination" (testMonitorAbnormalTermination transport True  True)
    , testCase "UnmonitorDisconnect"          (testMonitorDisconnect          transport True  True)
    , testCase "UnlinkNormalTermination"      (testMonitorNormalTermination   transport False True)
    , testCase "UnlinkAbnormalTermination"    (testMonitorAbnormalTermination transport False True)
    , testCase "UnlinkDisconnect"             (testMonitorDisconnect          transport False True)
      -- Monitoring nodes and channels
    , testCase "MonitorNode"                  (testMonitorNode                transport)
    , testCase "MonitorChannel"               (testMonitorChannel             transport)
      -- Reconnect
    , testCase "Reconnect"                    (testReconnect                  transport transportInternals)
    ]
  ]

main :: IO ()
main = do
  Right transport <- createTransportExposeInternals "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)
