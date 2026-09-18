{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( TQueue,
    atomically,
    newTQueueIO,
    readTQueue,
    writeTQueue,
  )
import Control.Distributed.Process
  ( Handler (Handler),
    MonitorRef,
    NodeId,
    Process,
    ProcessId,
    ProcessMonitorNotification (ProcessMonitorNotification),
    ReceivePort,
    SendPort,
    WhereIsReply (WhereIsReply),
    call,
    callLocal,
    catchExit,
    catches,
    catchesExit,
    delegate,
    die,
    exit,
    expect,
    expectTimeout,
    forward,
    getLocalNodeStats,
    getNodeStats,
    getProcessInfo,
    getSelfNode,
    getSelfPid,
    handleMessage,
    kill,
    liftIO,
    link,
    match,
    matchAny,
    matchChan,
    matchIf,
    matchMessage,
    matchSTM,
    matchUnknown,
    mergePortsBiased,
    mergePortsRR,
    monitor,
    monitorNode,
    monitorPort,
    newChan,
    nsend,
    nsendRemote,
    proxy,
    receiveChan,
    receiveChanTimeout,
    receiveTimeout,
    receiveWait,
    register,
    relay,
    reregister,
    send,
    sendChan,
    spawn,
    spawnChannel,
    spawnChannelLocal,
    spawnLocal,
    spawnMonitor,
    uforward,
    unlink,
    unmonitor,
    unregister,
    unsafeSend,
    unwrapMessage,
    usend,
    whereis,
    whereisRemoteAsync,
    withMonitor_,
    wrapMessage,
  )
import Control.Distributed.Process.Closure
  ( functionTDict,
    mkClosure,
    remotable,
    sdictUnit,
  )
import Control.Distributed.Process.Node
  ( LocalNode (..),
    closeLocalNode,
    forkProcess,
    initRemoteTable,
    newLocalNode,
    runProcess,
  )
import Control.Distributed.Process.Serializable (Serializable)
import qualified Control.Exception as E
import Control.Monad (forever, replicateM, replicateM_, void, when)
import qualified Control.Monad.Catch as Catch
import Data.Binary (Binary)
import qualified Data.ByteString.Char8 as BS
import GHC.Generics (Generic)
import qualified Network.Transport as NT
import Network.Transport.TCP
  ( createTransport,
    defaultTCPAddr,
    defaultTCPParameters,
  )
import Test.Tasty.Bench
  ( Benchmark,
    bench,
    bgroup,
    defaultMain,
    whnfIO,
  )

-- A top-level splice only brings names into scope for later declaration
-- groups, so these must precede 'main' and every use of 'mkClosure'.

remoteSignal :: ProcessId -> Process ()
remoteSignal them = send them ()

remoteChanEcho :: ProcessId -> ReceivePort () -> Process ()
remoteChanEcho them rp = receiveChan rp >> send them ()

remoteAnswer :: () -> Process Int
remoteAnswer () = return 42

remotable ['remoteSignal, 'remoteChanEcho, 'remoteAnswer]

main :: IO ()
main = do
  let rtable = __remoteTable initRemoteTable
  transport <-
    either E.throwIO return
      =<< createTransport (defaultTCPAddr "127.0.0.1" "0") defaultTCPParameters
  ( E.bracket (newLocalNode transport rtable) closeLocalNode $ \node1 ->
      E.bracket (newLocalNode transport rtable) closeLocalNode $ \node2 -> do
        fx <- setup node1 node2
        defaultMain (benchmarks fx)
    )
    `E.finally` NT.closeTransport transport

benchmarks :: Fixture -> [Benchmark]
benchmarks fx =
  [ bgroup
      "local"
      [ baseline fx,
        messaging fx,
        channels fx,
        receiving fx,
        messages fx,
        processes fx,
        monitoring fx,
        registry fx,
        exceptions fx,
        introspection fx,
        ring fx
      ],
    remote fx
  ]

-- | Cost of the harness alone, and so the floor below which the other numbers
-- say nothing.
baseline :: Fixture -> Benchmark
baseline fx =
  bgroup
    "baseline"
    [ oneBench fx "runner round trip (no work)" (return ()),
      repsBench fx "empty loop" 1000 (return ())
    ]

messaging :: Fixture -> Benchmark
messaging fx =
  bgroup
    "messaging"
    [ repsBench fx "send/expect" 1000 $ do
        us <- getSelfPid
        send echo us
        expect :: Process (),
      repsBench fx "usend/expect" 1000 $ do
        us <- getSelfPid
        usend echo us
        expect :: Process (),
      repsBench fx "unsafeSend/expect" 1000 $ do
        us <- getSelfPid
        unsafeSend echo us
        expect :: Process (),
      repsBench fx "nsend/expect" 100 $ do
        us <- getSelfPid
        nsend echoName us
        expect :: Process (),
      bgroup
        "throughput/bytestring"
        [ oneBench fx (show sz ++ "B") $
            sendThrough (fxCounter fx) 1000 (BS.replicate sz 'x')
        | sz <- [8, 1024, 65536]
        ],
      bgroup
        "throughput/list-of-int"
        [ oneBench fx (show n ++ "elems") $
            sendThrough (fxCounter fx) 1000 [1 .. n]
        | n <- [1, 100 :: Int]
        ]
    ]
  where
    echo = fxEcho fx

channels :: Fixture -> Benchmark
channels fx =
  bgroup
    "channels"
    [ repsBench fx "newChan" 100 $
        void (newChan :: Process (SendPort (), ReceivePort ())),
      repsBench fx "sendChan/receiveChan" 1000 $ do
        sendChan sp ()
        receiveChan rp,
      repsBench fx "receiveChanTimeout (empty)" 1000 $
        void (receiveChanTimeout 0 rp),
      repsBench fx "newChan + roundtrip via echo server" 100 $ do
        (sp', rp') <- newChan
        send (fxEcho fx) sp'
        receiveChan rp',
      repsBench fx "spawnChannelLocal" 100 $ do
        us <- getSelfPid
        sp' <- spawnChannelLocal $ \rp' ->
          (receiveChan rp' :: Process ()) >> send us ()
        sendChan sp' ()
        expect :: Process (),
      repsBench fx "mergePortsBiased" 100 (mergeBench mergePortsBiased),
      repsBench fx "mergePortsRR" 100 (mergeBench mergePortsRR)
    ]
  where
    (sp, rp) = fxChan fx

    mergeBench merge = do
      (sps, rps) <-
        unzip
          <$> replicateM 4 (newChan :: Process (SendPort (), ReceivePort ()))
      merged <- merge rps
      mapM_ (`sendChan` ()) sps
      replicateM_ 4 (receiveChan merged)

-- | Each of these puts one message in the runner's own mailbox and takes it
-- out again, so the spread between them is the cost of the 'Match'.
receiving :: Fixture -> Benchmark
receiving fx =
  bgroup
    "receiving"
    [ repsBench fx "expect" 1000 $ do
        selfSend ()
        expect :: Process (),
      repsBench fx "receiveWait (first of 1 match)" 1000 $ do
        selfSend ()
        receiveWait [match (\() -> return ())],
      repsBench fx "receiveWait (last of 6 matches)" 1000 $ do
        selfSend ()
        receiveWait
          [ match (\(_ :: Int) -> return ()),
            match (\(_ :: Bool) -> return ()),
            match (\(_ :: Char) -> return ()),
            match (\(_ :: BS.ByteString) -> return ()),
            match (\(_ :: Ping) -> return ()),
            match (\() -> return ())
          ],
      repsBench fx "matchIf" 1000 $ do
        selfSend (1 :: Int)
        receiveWait [matchIf (> (0 :: Int)) (\_ -> return ())],
      repsBench fx "matchAny" 1000 $ do
        selfSend ()
        receiveWait [matchAny (\_ -> return ())],
      repsBench fx "matchUnknown" 1000 $ do
        selfSend ()
        receiveWait [match (\(_ :: Int) -> return ()), matchUnknown (return ())],
      repsBench fx "matchMessage" 1000 $ do
        selfSend ()
        void (receiveWait [matchMessage return]),
      repsBench fx "matchChan" 1000 $ do
        sendChan sp ()
        receiveWait [matchChan rp return],
      repsBench fx "matchSTM" 1000 $ do
        liftIO (atomically (writeTQueue q ()))
        receiveWait [matchSTM (readTQueue q) return],
      repsBench fx "receiveTimeout (empty mailbox)" 1000 $
        void (receiveTimeout 0 [match (\() -> return ())]),
      repsBench fx "expectTimeout (hit)" 1000 $ do
        selfSend ()
        void (expectTimeout 0 :: Process (Maybe ()))
    ]
  where
    (sp, rp) = fxChan fx
    q = fxQueue fx

    selfSend :: (Serializable a) => a -> Process ()
    selfSend x = getSelfPid >>= \us -> unsafeSend us x

messages :: Fixture -> Benchmark
messages fx =
  bgroup
    "messages"
    [ repsBench fx "unwrapMessage (hit)" 1000 $
        void (unwrapMessage intMessage :: Process (Maybe Int)),
      repsBench fx "unwrapMessage (miss)" 1000 $
        void (unwrapMessage intMessage :: Process (Maybe Bool)),
      repsBench fx "handleMessage (hit)" 1000 $
        void (handleMessage intMessage (\(_ :: Int) -> return ())),
      repsBench fx "handleMessage (miss)" 1000 $
        void (handleMessage intMessage (\(_ :: Bool) -> return ())),
      repsBench fx "wrapMessage + unwrapMessage" 1000 $
        void (unwrapMessage (wrapMessage (42 :: Int)) :: Process (Maybe Int)),
      -- A 'ProcessId' is sent rather than @()@ so that 'echoServer' recognises
      -- the forwarded message and replies.
      repsBench fx "forward" 1000 $ do
        us <- getSelfPid
        unsafeSend us us
        receiveWait [matchAny (`forward` fxEcho fx)]
        expect :: Process (),
      repsBench fx "uforward" 1000 $ do
        us <- getSelfPid
        unsafeSend us us
        receiveWait [matchAny (`uforward` fxEcho fx)]
        expect :: Process (),
      repsBench fx "relay" 1000 $ do
        send (fxRelay fx) ()
        expect :: Process (),
      repsBench fx "delegate" 1000 $ do
        send (fxDelegate fx) ()
        expect :: Process (),
      repsBench fx "proxy" 1000 $ do
        send (fxProxy fx) ()
        expect :: Process ()
    ]
  where
    intMessage = wrapMessage (42 :: Int)

processes :: Fixture -> Benchmark
processes fx =
  bgroup
    "processes"
    [ repsBench fx "spawnLocal (sequential)" 100 $ do
        us <- getSelfPid
        _ <- spawnLocal (send us ())
        expect :: Process (),
      oneBench fx "spawnLocal (pipelined)" $ do
        us <- getSelfPid
        replicateM_ 100 (spawnLocal (send us ()))
        replicateM_ 100 (expect :: Process ()),
      repsBench fx "callLocal" 100 $
        callLocal (return ()),
      repsBench fx "getSelfPid" 1000 $
        void getSelfPid,
      repsBench fx "getSelfNode" 1000 $
        void getSelfNode
    ]

monitoring :: Fixture -> Benchmark
monitoring fx =
  bgroup
    "monitoring"
    [ repsBench fx "monitor/unmonitor" 100 $
        monitor echo >>= unmonitor,
      repsBench fx "withMonitor_" 100 $
        withMonitor_ echo (return ()),
      repsBench fx "link/unlink" 100 $
        link echo >> unlink echo,
      repsBench fx "monitorNode/unmonitor" 100 $
        (getSelfNode >>= monitorNode) >>= unmonitor,
      repsBench fx "monitorPort/unmonitor" 100 $
        monitorPort (fst (fxChan fx)) >>= unmonitor,
      repsBench fx "notification (normal exit)" 100 $ do
        pid <- spawnLocal (expect :: Process ())
        ref <- monitor pid
        send pid ()
        awaitDown ref,
      repsBench fx "notification (kill)" 100 $ do
        pid <- spawnLocal (expect :: Process ())
        ref <- monitor pid
        kill pid "benchmark"
        awaitDown ref,
      repsBench fx "notification (die)" 100 $ do
        pid <- spawnLocal (die "benchmark")
        ref <- monitor pid
        awaitDown ref,
      repsBench fx "exit caught by catchExit" 100 $ do
        pid <-
          spawnLocal $
            catchExit (expect :: Process ()) (\_ (_ :: String) -> return ())
        ref <- monitor pid
        exit pid "benchmark"
        awaitDown ref,
      repsBench fx "exit caught by catchesExit" 100 $ do
        pid <-
          spawnLocal $
            catchesExit
              (expect :: Process ())
              [\_ m -> handleMessage m (\(_ :: String) -> return ())]
        ref <- monitor pid
        exit pid "benchmark"
        awaitDown ref
    ]
  where
    echo = fxEcho fx

registry :: Fixture -> Benchmark
registry fx =
  bgroup
    "registry"
    [ repsBench fx "whereis (hit)" 100 $
        void (whereis echoName),
      repsBench fx "whereis (miss)" 100 $
        void (whereis "benchmarks.absent"),
      repsBench fx "register/unregister" 100 $ do
        register "benchmarks.tmp" (fxEcho fx)
        unregister "benchmarks.tmp",
      repsBench fx "reregister" 100 $
        reregister echoName (fxEcho fx)
    ]

exceptions :: Fixture -> Benchmark
exceptions fx =
  bgroup
    "exceptions"
    [ repsBench fx "catch (not thrown)" 1000 $
        Catch.catch (return ()) (\(_ :: E.SomeException) -> return ()),
      repsBench fx "catch (thrown)" 1000 $
        Catch.catch (Catch.throwM Boom) (\Boom -> return ()),
      repsBench fx "try" 1000 $
        void (Catch.try (return ()) :: Process (Either E.SomeException ())),
      repsBench fx "catches (distributed-process Handler)" 1000 $
        catches
          (return ())
          [ Handler (\(_ :: E.ArithException) -> return ()),
            Handler (\(_ :: E.SomeException) -> return ())
          ],
      repsBench fx "bracket" 1000 $
        Catch.bracket (return ()) (\_ -> return ()) (\_ -> return ()),
      repsBench fx "finally" 1000 $
        Catch.finally (return ()) (return ()),
      repsBench fx "onException" 1000 $
        Catch.onException (return ()) (return ()),
      repsBench fx "mask_" 1000 $
        Catch.mask_ (return ())
    ]

introspection :: Fixture -> Benchmark
introspection fx =
  bgroup
    "introspection"
    [ repsBench fx "getProcessInfo" 100 $
        void (getProcessInfo (fxEcho fx)),
      repsBench fx "getLocalNodeStats" 100 $
        void getLocalNodeStats,
      repsBench fx "getNodeStats" 100 $
        void (getSelfNode >>= getNodeStats)
    ]

-- | 100 laps around each of the rings built by 'setup'.
ring :: Fixture -> Benchmark
ring fx =
  bgroup
    "ring"
    [ oneBench fx nm $ do
        replicateM_ 100 (send entry (Ping 0))
        replicateM_ 100 (void (expect :: Process Ping))
    | (nm, entry) <- fxRings fx
    ]

remote :: Fixture -> Benchmark
remote fx =
  bgroup
    "remote"
    [ repsBench fx "send/expect" 100 $ do
        us <- getSelfPid
        send echo us
        expect :: Process (),
      repsBench fx "usend/expect" 100 $ do
        us <- getSelfPid
        usend echo us
        expect :: Process (),
      repsBench fx "newChan + sendChan/receiveChan" 100 $ do
        (sp, rp) <- newChan
        send echo sp
        receiveChan rp,
      bgroup
        "throughput/bytestring"
        [ oneBench fx (show sz ++ "B") $
            sendThrough (fxRemoteCounter fx) 100 (BS.replicate sz 'x')
        | sz <- [8, 1024, 65536]
        ],
      repsBench fx "nsendRemote/expect" 100 $ do
        us <- getSelfPid
        nsendRemote nid echoName us
        expect :: Process (),
      repsBench fx "whereisRemoteAsync" 100 $ do
        whereisRemoteAsync nid echoName
        receiveWait
          [ matchIf
              (\(WhereIsReply n _) -> n == echoName)
              (\_ -> return ())
          ],
      repsBench fx "spawn" 100 $ do
        us <- getSelfPid
        _ <- spawn nid ($(mkClosure 'remoteSignal) us)
        expect :: Process (),
      repsBench fx "spawnMonitor + notification" 100 $ do
        us <- getSelfPid
        (_, ref) <- spawnMonitor nid ($(mkClosure 'remoteSignal) us)
        expect :: Process ()
        awaitDown ref,
      repsBench fx "spawnChannel" 100 $ do
        us <- getSelfPid
        sp <- spawnChannel sdictUnit nid ($(mkClosure 'remoteChanEcho) us)
        sendChan sp ()
        expect :: Process (),
      repsBench fx "call" 100 $
        void
          ( call
              $(functionTDict 'remoteAnswer)
              nid
              ($(mkClosure 'remoteAnswer) ())
          ),
      repsBench fx "getNodeStats" 100 $
        void (getNodeStats nid),
      repsBench fx "getProcessInfo" 100 $
        void (getProcessInfo echo)
    ]
  where
    echo = fxRemoteEcho fx
    nid = fxRemoteNodeId fx

-- | tasty-bench already repeats the body of the benchmark, but the benchmark
-- fixture adds a baseline amount of time which drowns some of the faster benchmarks.
--
-- Therefore, we amortize the fixture overhead by looping.
repsBench :: Fixture -> String -> Int -> Process () -> Benchmark
repsBench fx name reps act =
  bench (name ++ " (x" ++ show reps ++ ")") $
    whnfIO (fxRun fx (replicateM_ reps act))

oneBench :: Fixture -> String -> Process () -> Benchmark
oneBench fx name act = bench name $ whnfIO (fxRun fx act)

data Fixture = Fixture
  { fxRun :: Process () -> IO (),
    fxRemoteNodeId :: NodeId,
    fxEcho :: ProcessId,
    fxCounter :: ProcessId,
    fxRemoteEcho :: ProcessId,
    fxRemoteCounter :: ProcessId,
    fxChan :: (SendPort (), ReceivePort ()),
    fxQueue :: TQueue (),
    fxRelay :: ProcessId,
    fxDelegate :: ProcessId,
    fxProxy :: ProcessId,
    fxRings :: [(String, ProcessId)]
  }

echoName :: String
echoName = "benchmarks.echo"

setup :: LocalNode -> LocalNode -> IO Fixture
setup node1 node2 = do
  run <- newRunner node1
  queue <- newTQueueIO
  echo <- forkProcess node1 echoServer
  counter <- forkProcess node1 counterServer
  remoteEcho <- forkProcess node2 echoServer
  remoteCount <- forkProcess node2 counterServer
  -- 'register' acts on the caller's node.
  runProcess node1 (register echoName echo)
  runProcess node2 (register echoName remoteEcho)
  -- 'relay', 'delegate' and 'proxy' never return, so they cannot be spawned
  -- per iteration. They, the rings and the shared channel all have to be
  -- rooted at the runner, since that is the process each iteration runs on.
  var <- newEmptyMVar
  run $ do
    self <- getSelfPid
    chan <- newChan
    rly <- spawnLocal (relay self)
    dlg <- spawnLocal (delegate self (const True))
    prx <- spawnLocal (proxy self (\() -> return True))
    rings <-
      mapM
        (\(nm, mode) -> (,) nm <$> makeRing mode 10 self)
        [ ("send", RelaySend),
          ("unsafeSend", RelayUnsafeSend),
          ("forward", RelayForward)
        ]
    liftIO $ putMVar var (chan, rly, dlg, prx, rings)
  (chan, rly, dlg, prx, rings) <- takeMVar var
  return
    Fixture
      { fxRun = run,
        fxRemoteNodeId = localNodeId node2,
        fxEcho = echo,
        fxCounter = counter,
        fxRemoteEcho = remoteEcho,
        fxRemoteCounter = remoteCount,
        fxChan = chan,
        fxQueue = queue,
        fxRelay = rly,
        fxDelegate = dlg,
        fxProxy = prx,
        fxRings = rings
      }

-- | Runs actions on one long-lived process. Using 'runProcess' instead would
-- fold a 'forkProcess' into every measurement and give each iteration a fresh
-- 'ProcessId', defeating the connection caching real applications rely on.
newRunner :: LocalNode -> IO (Process () -> IO ())
newRunner node = do
  reqVar <- newEmptyMVar
  respVar <- newEmptyMVar
  _ <- forkProcess node $ forever $ do
    act <- liftIO (takeMVar reqVar)
    r <- Catch.try act
    drainMailbox
    liftIO $ putMVar respVar (r :: Either E.SomeException ())
  return $ \act -> do
    putMVar reqVar act
    takeMVar respVar >>= either E.throwIO return

-- | Keeps a benchmark from perturbing later ones through the runner's mailbox.
drainMailbox :: Process ()
drainMailbox = do
  r <- receiveTimeout 0 [matchAny (\_ -> return ())]
  case r of
    Nothing -> return ()
    Just () -> drainMailbox

awaitDown :: MonitorRef -> Process ()
awaitDown ref =
  receiveWait
    [ matchIf
        (\(ProcessMonitorNotification ref' _ _) -> ref' == ref)
        (\_ -> return ())
    ]

-- | Pipelined throughput: @n@ one-way sends, then one round trip to confirm
-- they all arrived.
sendThrough :: (Serializable a) => ProcessId -> Int -> a -> Process ()
sendThrough srv n payload = do
  us <- getSelfPid
  replicateM_ n (send srv payload)
  send srv (Report us)
  n' <- expect
  when (n' /= n) $
    die ("expected " ++ show n ++ " messages, server saw " ++ show n')

-- | The trailing 'matchAny' stops the mailbox growing if a benchmark sends
-- something unexpected; a growing mailbox is rescanned on every 'receiveWait'
-- and would skew every benchmark that follows.
echoServer :: Process ()
echoServer =
  forever $
    receiveWait
      [ match $ \(them :: ProcessId) -> send them (),
        match $ \(them, n :: Int) -> send them n,
        match $ \(them, bs :: BS.ByteString) -> send them bs,
        match $ \(sp :: SendPort ()) -> sendChan sp (),
        matchAny $ \_ -> return ()
      ]

-- | Counts one-way messages, and on 'Report' replies with the number seen
-- since the last report.
counterServer :: Process ()
counterServer = go 0
  where
    go :: Int -> Process ()
    go !n =
      receiveWait
        [ match $ \(Report them) -> send them n >> go 0,
          matchAny $ \_ -> go (n + 1)
        ]

data RelayMode = RelaySend | RelayUnsafeSend | RelayForward

relayLoop :: RelayMode -> ProcessId -> Process ()
relayLoop mode next = forever $ case mode of
  RelaySend -> expect >>= \m -> send next (m :: Ping)
  RelayUnsafeSend -> expect >>= \m -> unsafeSend next (m :: Ping)
  RelayForward -> receiveWait [matchAny (`forward` next)]

-- | Ring of @n@ relays whose last member relays to @target@; returns the entry
-- point.
makeRing :: RelayMode -> Int -> ProcessId -> Process ProcessId
makeRing mode n target
  | n <= 0 = return target
  | otherwise = makeRing mode (n - 1) =<< spawnLocal (relayLoop mode target)

newtype Ping = Ping Int
  deriving (Generic)

instance Binary Ping

newtype Report = Report ProcessId
  deriving (Generic)

instance Binary Report

data Boom = Boom
  deriving (Show)

instance E.Exception Boom
