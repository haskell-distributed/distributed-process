-- | Cloud Haskell primitives
--
-- We define these in a separate module so that we don't have to rely on
-- the closure combinators
module Control.Distributed.Process.Internal.Primitives
  ( -- * Basic messaging
    send
  , expect
    -- * Channels
  , newChan
  , sendChan
  , receiveChan
  , mergePortsBiased
  , mergePortsRR
    -- * Advanced messaging
  , Match
  , receiveWait
  , receiveTimeout
  , match
  , matchIf
  , matchUnknown
  , AbstractMessage(..)
  , matchAny
  , matchChan
    -- * Process management
  , terminate
  , ProcessTerminationException(..)
  , kill
  , ProcessKillException(..)
  , exit
  , catchExit
  , ProcessExitException(..)
  , getSelfPid
  , getSelfNode
  , ProcessInfo(..)
  , getProcessInfo
    -- * Monitoring and linking
  , link
  , unlink
  , monitor
  , unmonitor
  , withMonitor
    -- * Logging
  , say
    -- * Registry
  , register
  , reregister
  , unregister
  , whereis
  , nsend
  , registerRemoteAsync
  , reregisterRemoteAsync
  , unregisterRemoteAsync
  , whereisRemoteAsync
  , nsendRemote
    -- * Closures
  , unClosure
  , unStatic
    -- * Exception handling
  , catch
  , try
  , mask
  , onException
  , bracket
  , bracket_
  , finally
    -- * Auxiliary API
  , expectTimeout
  , receiveChanTimeout
  , spawnAsync
  , linkNode
  , linkPort
  , unlinkNode
  , unlinkPort
  , monitorNode
  , monitorPort
    -- * Reconnecting
  , reconnect
  , reconnectPort
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Data.Binary (decode)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime)
import System.IO (hPutStrLn, stderr)
import System.Locale (defaultTimeLocale)
import System.Timeout (timeout)
import Control.Monad (when)
import Control.Monad.Reader (ask)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, SomeException)
import qualified Control.Exception as Ex (catch, mask, try)
import Control.Distributed.Process.Internal.StrictMVar
  ( StrictMVar
  , modifyMVar
  , modifyMVar_
  )
import Control.Concurrent (ThreadId)
import Control.Concurrent.Chan (writeChan)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , orElse
  , newTVar
  , readTVar
  , writeTVar
  )
import Control.Distributed.Process.Internal.CQueue
  ( dequeue
  , BlockSpec(..)
  , MatchOn(..)
  )
import Control.Distributed.Process.Serializable (Serializable, fingerprint)
import Data.Accessor ((^.), (^:), (^=))
import Control.Distributed.Static (Closure, Static)
import Data.Rank1Typeable (Typeable)
import qualified Control.Distributed.Static as Static (unstatic, unclosure)
import Control.Distributed.Process.Internal.Types
  ( NodeId(..)
  , ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , Message(..)
  , MonitorRef(..)
  , SpawnRef(..)
  , NCMsg(..)
  , ProcessSignal(..)
  , monitorCounter
  , spawnCounter
  , SendPort(..)
  , ReceivePort(..)
  , channelCounter
  , typedChannelWithId
  , TypedChannel(..)
  , SendPortId(..)
  , Identifier(..)
  , DidUnmonitor(..)
  , DidUnlinkProcess(..)
  , DidUnlinkNode(..)
  , DidUnlinkPort(..)
  , WhereIsReply(..)
  , RegisterReply(..)
  , ProcessRegistrationException(..)
  , ProcessInfo(..)
  , ProcessInfoNone(..)
  , createMessage
  , runLocalProcess
  , ImplicitReconnect(WithImplicitReconnect, NoImplicitReconnect)
  , LocalProcessState
  , LocalSendPortId
  , messageToPayload
  )
import Control.Distributed.Process.Internal.Messaging
  ( sendMessage
  , sendBinary
  , sendPayload
  , disconnect
  )
import Control.Distributed.Process.Internal.WeakTQueue
  ( newTQueueIO
  , readTQueue
  , mkWeakTQueue
  )

--------------------------------------------------------------------------------
-- Basic messaging                                                            --
--------------------------------------------------------------------------------

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
-- This requires a lookup on every send. If we want to avoid that we need to
-- modify serializable to allow for stateful (IO) deserialization
send them msg = do
  proc <- ask
  liftIO $ sendMessage (processNode proc)
                       (ProcessIdentifier (processId proc))
                       (ProcessIdentifier them)
                       NoImplicitReconnect
                       msg

-- | Wait for a message of a specific type
expect :: forall a. Serializable a => Process a
expect = receiveWait [match return]

--------------------------------------------------------------------------------
-- Channels                                                                   --
--------------------------------------------------------------------------------

-- | Create a new typed channel
newChan :: Serializable a => Process (SendPort a, ReceivePort a)
newChan = do
    proc <- ask
    liftIO . modifyMVar (processState proc) $ \st -> do
      let lcid  = st ^. channelCounter
      let cid   = SendPortId { sendPortProcessId = processId proc
                             , sendPortLocalId   = lcid
                             }
      let sport = SendPort cid
      chan  <- liftIO newTQueueIO
      chan' <- mkWeakTQueue chan $ finalizer (processState proc) lcid
      let rport = ReceivePort $ readTQueue chan
      let tch   = TypedChannel chan'
      return ( (channelCounter ^: (+ 1))
             . (typedChannelWithId lcid ^= Just tch)
             $ st
             , (sport, rport)
             )
  where
    finalizer :: StrictMVar LocalProcessState -> LocalSendPortId -> IO ()
    finalizer st lcid = modifyMVar_ st $
      return . (typedChannelWithId lcid ^= Nothing)

-- | Send a message on a typed channel
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan (SendPort cid) msg = do
  proc <- ask
  liftIO $ sendBinary (processNode proc)
                      (ProcessIdentifier (processId proc))
                      (SendPortIdentifier cid)
                      NoImplicitReconnect
                      msg

-- | Wait for a message on a typed channel
receiveChan :: Serializable a => ReceivePort a -> Process a
receiveChan = liftIO . atomically . receiveSTM

-- | Like 'receiveChan' but with a timeout. If the timeout is 0, do a
-- non-blocking check for a message.
receiveChanTimeout :: Serializable a => Int -> ReceivePort a -> Process (Maybe a)
receiveChanTimeout 0 ch = liftIO . atomically $
  (Just <$> receiveSTM ch) `orElse` return Nothing
receiveChanTimeout n ch = liftIO . timeout n . atomically $
  receiveSTM ch

-- | Merge a list of typed channels.
--
-- The result port is left-biased: if there are messages available on more
-- than one port, the first available message is returned.
mergePortsBiased :: Serializable a => [ReceivePort a] -> Process (ReceivePort a)
mergePortsBiased = return . ReceivePort. foldr1 orElse . map receiveSTM

-- | Like 'mergePortsBiased', but with a round-robin scheduler (rather than
-- left-biased)
mergePortsRR :: Serializable a => [ReceivePort a] -> Process (ReceivePort a)
mergePortsRR = \ps -> do
    psVar <- liftIO . atomically $ newTVar (map receiveSTM ps)
    return $ ReceivePort (rr psVar)
  where
    rotate :: [a] -> [a]
    rotate []     = []
    rotate (x:xs) = xs ++ [x]

    rr :: TVar [STM a] -> STM a
    rr psVar = do
      ps <- readTVar psVar
      a  <- foldr1 orElse ps
      writeTVar psVar (rotate ps)
      return a

--------------------------------------------------------------------------------
-- Advanced messaging                                                         --
--------------------------------------------------------------------------------

-- | Opaque type used in 'receiveWait' and 'receiveTimeout'
newtype Match b = Match { unMatch :: MatchOn Message (Process b) }

-- | Test the matches in order against each message in the queue
receiveWait :: [Match b] -> Process b
receiveWait ms = do
  queue <- processQueue <$> ask
  Just proc <- liftIO $ dequeue queue Blocking (map unMatch ms)
  proc

-- | Like 'receiveWait' but with a timeout.
--
-- If the timeout is zero do a non-blocking check for matching messages. A
-- non-zero timeout is applied only when waiting for incoming messages (that is,
-- /after/ we have checked the messages that are already in the mailbox).
receiveTimeout :: Int -> [Match b] -> Process (Maybe b)
receiveTimeout t ms = do
  queue <- processQueue <$> ask
  let blockSpec = if t == 0 then NonBlocking else Timeout t
  mProc <- liftIO $ dequeue queue blockSpec (map unMatch ms)
  case mProc of
    Nothing   -> return Nothing
    Just proc -> Just <$> proc

matchChan :: ReceivePort a -> (a -> Process b) -> Match b
matchChan p fn = Match $ MatchChan (fmap fn (receiveSTM p))

-- | Match against any message of the right type
match :: forall a b. Serializable a => (a -> Process b) -> Match b
match = matchIf (const True)

-- | Match against any message of the right type that satisfies a predicate
matchIf :: forall a b. Serializable a => (a -> Bool) -> (a -> Process b) -> Match b
matchIf c p = Match $ MatchMsg $ \msg ->
   case messageFingerprint msg == fingerprint (undefined :: a) of
     True | c decoded -> Just (p decoded)
       where
         decoded :: a
         -- Make sure the value is fully decoded so that we don't hang to
         -- bytestrings when the process calling 'matchIf' doesn't process
         -- the values immediately
         !decoded = decode (messageEncoding msg)
     _ -> Nothing

data AbstractMessage = AbstractMessage {
    forward :: ProcessId -> Process ()
  }

-- | Match against an arbitrary message
matchAny :: forall b. (AbstractMessage -> Process b) -> Match b
matchAny p = Match $ MatchMsg $ Just . p . abstract
  where
    abstract :: Message -> AbstractMessage
    abstract msg = AbstractMessage {
        forward = \them -> do
          proc <- ask
          liftIO $ sendPayload (processNode proc)
                               (ProcessIdentifier (processId proc))
                               (ProcessIdentifier them)
                               NoImplicitReconnect
                               (messageToPayload msg)
      }

-- | Remove any message from the queue
matchUnknown :: Process b -> Match b
matchUnknown p = Match $ MatchMsg (const (Just p))

--------------------------------------------------------------------------------
-- Process management                                                         --
--------------------------------------------------------------------------------

-- | Thrown by 'terminate'
data ProcessTerminationException = ProcessTerminationException
  deriving (Show, Typeable)

instance Exception ProcessTerminationException

-- | Terminate (throws a ProcessTerminationException)
terminate :: Process a
terminate = liftIO $ throwIO ProcessTerminationException

-- | Forceful request to kill a process
kill :: ProcessId -> String -> Process ()
-- NOTE: We send the message to our local node controller, which will then
-- forward it to a remote node controller (if applicable). Sending it directly
-- to a remote node controller means that that the message may overtake a
-- 'monitor' or 'link' request.
kill them reason = sendCtrlMsg Nothing (Kill them reason)

-- | Thrown by 'kill'
data ProcessKillException =
    ProcessKillException !ProcessId !String
  deriving (Typeable)

instance Exception ProcessKillException
instance Show ProcessKillException where
  show (ProcessKillException pid reason) = "Kill by " ++ show pid ++ ": " ++ reason

-- | Graceful request to exit a process
exit :: Serializable a => ProcessId -> a -> Process ()
-- NOTE: We send the message to our local node controller, which will then
-- forward it to a remote node controller (if applicable). Sending it directly
-- to a remote node controller means that that the message may overtake a
-- 'monitor' or 'link' request.
exit them reason = sendCtrlMsg Nothing (Exit them (createMessage reason))

-- | Internal exception thrown indirectly by 'exit'
data ProcessExitException =
    ProcessExitException !ProcessId !Message
  deriving Typeable

instance Exception ProcessExitException
instance Show ProcessExitException where
  show (ProcessExitException pid _) = "Exit by " ++ show pid

-- | Catches ProcessExitException
catchExit :: forall a b . (Show a, Serializable a) => Process b -> (ProcessId -> a -> Process b) -> Process b
catchExit act exitHandler = catch act handleExit
  where
    handleExit ex@(ProcessExitException from msg) =
        if messageFingerprint msg == fingerprint (undefined :: a)
          then exitHandler from decoded
          else liftIO $ throwIO ex
     where
       decoded :: a
       -- Make sure the value is fully decoded so that we don't hang to
       -- bytestrings when the process calling 'matchIf' doesn't process
       -- the values immediately
       !decoded = decode (messageEncoding msg)

-- | Our own process ID
getSelfPid :: Process ProcessId
getSelfPid = processId <$> ask

-- | Get the node ID of our local node
getSelfNode :: Process NodeId
getSelfNode = localNodeId . processNode <$> ask

-- | Get information about the specified process
getProcessInfo :: ProcessId -> Process (Maybe ProcessInfo)
getProcessInfo pid =
  let them = processNodeId pid in do
  us <- getSelfNode
  dest <- mkNode them us
  sendCtrlMsg dest $ GetInfo pid
  receiveWait [
       match (\(p :: ProcessInfo)     -> return $ Just p)
     , match (\(_ :: ProcessInfoNone) -> return Nothing)
     ]
  where mkNode :: NodeId -> NodeId -> Process (Maybe NodeId)
        mkNode them us = case them == us of
                           True -> return Nothing
                           _    -> return $ Just them

--------------------------------------------------------------------------------
-- Monitoring and linking                                                     --
--------------------------------------------------------------------------------

-- | Link to a remote process (asynchronous)
--
-- When process A links to process B (that is, process A calls
-- @link pidB@) then an asynchronous exception will be thrown to process A
-- when process B terminates (normally or abnormally), or when process A gets
-- disconnected from process B. Although it is /technically/ possible to catch
-- these exceptions, chances are if you find yourself trying to do so you should
-- probably be using 'monitor' rather than 'link'. In particular, code such as
--
-- > link pidB   -- Link to process B
-- > expect      -- Wait for a message from process B
-- > unlink pidB -- Unlink again
--
-- doesn't quite do what one might expect: if process B sends a message to
-- process A, and /subsequently terminates/, then process A might or might not
-- be terminated too, depending on whether the exception is thrown before or
-- after the 'unlink' (i.e., this code has a race condition).
--
-- Linking is all-or-nothing: A is either linked to B, or it's not. A second
-- call to 'link' has no effect.
--
-- Note that 'link' provides unidirectional linking (see 'spawnSupervised').
-- Linking makes no distinction between normal and abnormal termination of
-- the remote process.
link :: ProcessId -> Process ()
link = sendCtrlMsg Nothing . Link . ProcessIdentifier

-- | Monitor another process (asynchronous)
--
-- When process A monitors process B (that is, process A calls
-- @monitor pidB@) then process A will receive a 'ProcessMonitorNotification'
-- when process B terminates (normally or abnormally), or when process A gets
-- disconnected from process B. You receive this message like any other (using
-- 'expect'); the notification includes a reason ('DiedNormal', 'DiedException',
-- 'DiedDisconnect', etc.).
--
-- Every call to 'monitor' returns a new monitor reference 'MonitorRef'; if
-- multiple monitors are set up, multiple notifications will be delivered
-- and monitors can be disabled individually using 'unmonitor'.
monitor :: ProcessId -> Process MonitorRef
monitor = monitor' . ProcessIdentifier

-- | Establishes temporary monitoring of another process.
--
-- @withMonitor pid code@ sets up monitoring of @pid@ for the duration
-- of @code@.  Note: although monitoring is no longer active when
-- @withMonitor@ returns, there might still be unreceived monitor
-- messages in the queue.
--
withMonitor :: ProcessId -> Process a -> Process a
withMonitor pid code = bracket (monitor pid) unmonitor (\_ -> code)
  -- unmonitor blocks waiting for the response, so there's a possibility
  -- that an exception might interrupt withMonitor before the unmonitor
  -- has completed.  I think that's better than making the unmonitor
  -- uninterruptible.

-- | Remove a link
--
-- This is synchronous in the sense that once it returns you are guaranteed
-- that no exception will be raised if the remote process dies. However, it is
-- asynchronous in the sense that we do not wait for a response from the remote
-- node.
unlink :: ProcessId -> Process ()
unlink pid = do
  unlinkAsync pid
  receiveWait [ matchIf (\(DidUnlinkProcess pid') -> pid' == pid)
                        (\_ -> return ())
              ]

-- | Remove a node link
--
-- This has the same synchronous/asynchronous nature as 'unlink'.
unlinkNode :: NodeId -> Process ()
unlinkNode nid = do
  unlinkNodeAsync nid
  receiveWait [ matchIf (\(DidUnlinkNode nid') -> nid' == nid)
                        (\_ -> return ())
              ]

-- | Remove a channel (send port) link
--
-- This has the same synchronous/asynchronous nature as 'unlink'.
unlinkPort :: SendPort a -> Process ()
unlinkPort sport = do
  unlinkPortAsync sport
  receiveWait [ matchIf (\(DidUnlinkPort cid) -> cid == sendPortId sport)
                        (\_ -> return ())
              ]

-- | Remove a monitor
--
-- This has the same synchronous/asynchronous nature as 'unlink'.
unmonitor :: MonitorRef -> Process ()
unmonitor ref = do
  unmonitorAsync ref
  receiveWait [ matchIf (\(DidUnmonitor ref') -> ref' == ref)
                        (\_ -> return ())
              ]

--------------------------------------------------------------------------------
-- Exception handling                                                         --
--------------------------------------------------------------------------------

-- | Lift 'Control.Exception.catch'
catch :: Exception e => Process a -> (e -> Process a) -> Process a
catch p h = do
  lproc <- ask
  liftIO $ Ex.catch (runLocalProcess lproc p) (runLocalProcess lproc . h)

-- | Lift 'Control.Exception.try'
try :: Exception e => Process a -> Process (Either e a)
try p = do
  lproc <- ask
  liftIO $ Ex.try (runLocalProcess lproc p)

-- | Lift 'Control.Exception.mask'
mask :: ((forall a. Process a -> Process a) -> Process b) -> Process b
mask p = do
    lproc <- ask
    liftIO $ Ex.mask $ \restore ->
      runLocalProcess lproc (p (liftRestore lproc restore))
  where
    liftRestore :: LocalProcess -> (forall a. IO a -> IO a) -> (forall a. Process a -> Process a)
    liftRestore lproc restoreIO = liftIO . restoreIO . runLocalProcess lproc

-- | Lift 'Control.Exception.onException'
onException :: Process a -> Process b -> Process a
onException p what = p `catch` \e -> do _ <- what
                                        liftIO $ throwIO (e :: SomeException)

-- | Lift 'Control.Exception.bracket'
bracket :: Process a -> (a -> Process b) -> (a -> Process c) -> Process c
bracket before after thing =
  mask $ \restore -> do
    a <- before
    r <- restore (thing a) `onException` after a
    _ <- after a
    return r

-- | Lift 'Control.Exception.bracket_'
bracket_ :: Process a -> Process b -> Process c -> Process c
bracket_ before after thing = bracket before (const after) (const thing)

-- | Lift 'Control.Exception.finally'
finally :: Process a -> Process b -> Process a
finally a sequel = bracket_ (return ()) sequel a

--------------------------------------------------------------------------------
-- Auxiliary API                                                              --
--------------------------------------------------------------------------------

-- | Like 'expect' but with a timeout
expectTimeout :: forall a. Serializable a => Int -> Process (Maybe a)
expectTimeout n = receiveTimeout n [match return]

-- | Asynchronous version of 'spawn'
--
-- ('spawn' is defined in terms of 'spawnAsync' and 'expect')
spawnAsync :: NodeId -> Closure (Process ()) -> Process SpawnRef
spawnAsync nid proc = do
  spawnRef <- getSpawnRef
  sendCtrlMsg (Just nid) $ Spawn proc spawnRef
  return spawnRef

-- | Monitor a node (asynchronous)
monitorNode :: NodeId -> Process MonitorRef
monitorNode =
  monitor' . NodeIdentifier

-- | Monitor a typed channel (asynchronous)
monitorPort :: forall a. Serializable a => SendPort a -> Process MonitorRef
monitorPort (SendPort cid) =
  monitor' (SendPortIdentifier cid)

-- | Remove a monitor (asynchronous)
unmonitorAsync :: MonitorRef -> Process ()
unmonitorAsync =
  sendCtrlMsg Nothing . Unmonitor

-- | Link to a node (asynchronous)
linkNode :: NodeId -> Process ()
linkNode = link' . NodeIdentifier

-- | Link to a channel (asynchronous)
linkPort :: SendPort a -> Process ()
linkPort (SendPort cid) =
  link' (SendPortIdentifier cid)

-- | Remove a process link (asynchronous)
unlinkAsync :: ProcessId -> Process ()
unlinkAsync =
  sendCtrlMsg Nothing . Unlink . ProcessIdentifier

-- | Remove a node link (asynchronous)
unlinkNodeAsync :: NodeId -> Process ()
unlinkNodeAsync =
  sendCtrlMsg Nothing . Unlink . NodeIdentifier

-- | Remove a channel (send port) link (asynchronous)
unlinkPortAsync :: SendPort a -> Process ()
unlinkPortAsync (SendPort cid) =
  sendCtrlMsg Nothing . Unlink $ SendPortIdentifier cid

--------------------------------------------------------------------------------
-- Logging                                                                    --
--------------------------------------------------------------------------------

-- | Log a string
--
-- @say message@ sends a message (time, pid of the current process, message)
-- to the process registered as 'logger'.  By default, this process simply
-- sends the string to 'stderr'. Individual Cloud Haskell backends might
-- replace this with a different logger process, however.
say :: String -> Process ()
say string = do
  now <- liftIO getCurrentTime
  us  <- getSelfPid
  nsend "logger" (formatTime defaultTimeLocale "%c" now, us, string)

--------------------------------------------------------------------------------
-- Registry                                                                   --
--------------------------------------------------------------------------------

-- | Register a process with the local registry (asynchronous).
-- This version will wait until a response is gotten from the
-- management process. The name must not already be registered.
-- The process need not be on this node.
-- A bad registration will result in a 'ProcessRegistrationException'
--
-- The process to be registered does not have to be local itself.
register :: String -> ProcessId -> Process ()
register = registerImpl False

-- | Like 'register', but will replace an existing registration.
-- The name must already be registered.
reregister :: String -> ProcessId -> Process ()
reregister = registerImpl True

registerImpl :: Bool -> String -> ProcessId -> Process ()
registerImpl force label pid = do
  mynid <- getSelfNode
  sendCtrlMsg Nothing (Register label mynid (Just pid) force)
  receiveWait [ matchIf (\(RegisterReply label' _) -> label == label')
                        (\(RegisterReply _ ok) -> handleRegistrationReply label ok)
              ]

-- | Register a process with a remote registry (asynchronous).
--
-- The process to be registered does not have to live on the same remote node.
-- Reply wil come in the form of a 'RegisterReply' message
--
-- See comments in 'whereisRemoteAsync'
registerRemoteAsync :: NodeId -> String -> ProcessId -> Process ()
registerRemoteAsync nid label pid =
  sendCtrlMsg (Just nid) (Register label nid (Just pid) False)

reregisterRemoteAsync :: NodeId -> String -> ProcessId -> Process ()
reregisterRemoteAsync nid label pid =
  sendCtrlMsg (Just nid) (Register label nid (Just pid) True)

-- | Remove a process from the local registry (asynchronous).
-- This version will wait until a response is gotten from the
-- management process. The name must already be registered.
unregister :: String -> Process ()
unregister label = do
  mynid <- getSelfNode
  sendCtrlMsg Nothing (Register label mynid Nothing False)
  receiveWait [ matchIf (\(RegisterReply label' _) -> label == label')
                        (\(RegisterReply _ ok) -> handleRegistrationReply label ok)
              ]

-- | Deal with the result from an attempted registration or unregistration
-- by throwing an exception if necessary
handleRegistrationReply :: String -> Bool -> Process ()
handleRegistrationReply label ok =
  when (not ok) $
     liftIO $ throwIO $ ProcessRegistrationException label

-- | Remove a process from a remote registry (asynchronous).
--
-- Reply wil come in the form of a 'RegisterReply' message
--
-- See comments in 'whereisRemoteAsync'
unregisterRemoteAsync :: NodeId -> String -> Process ()
unregisterRemoteAsync nid label =
  sendCtrlMsg (Just nid) (Register label nid Nothing False)

-- | Query the local process registry
whereis :: String -> Process (Maybe ProcessId)
whereis label = do
  sendCtrlMsg Nothing (WhereIs label)
  receiveWait [ matchIf (\(WhereIsReply label' _) -> label == label')
                        (\(WhereIsReply _ mPid) -> return mPid)
              ]

-- | Query a remote process registry (asynchronous)
--
-- Reply will come in the form of a 'WhereIsReply' message.
--
-- There is currently no synchronous version of 'whereisRemoteAsync': if
-- you implement one yourself, be sure to take into account that the remote
-- node might die or get disconnect before it can respond (i.e. you should
-- use 'monitorNode' and take appropriate action when you receive a
-- 'NodeMonitorNotification').
whereisRemoteAsync :: NodeId -> String -> Process ()
whereisRemoteAsync nid label =
  sendCtrlMsg (Just nid) (WhereIs label)

-- | Named send to a process in the local registry (asynchronous)
nsend :: Serializable a => String -> a -> Process ()
nsend label msg =
  sendCtrlMsg Nothing (NamedSend label (createMessage msg))

-- | Named send to a process in a remote registry (asynchronous)
nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote nid label msg =
  sendCtrlMsg (Just nid) (NamedSend label (createMessage msg))

--------------------------------------------------------------------------------
-- Closures                                                                   --
--------------------------------------------------------------------------------

-- | Resolve a static value
unStatic :: Typeable a => Static a -> Process a
unStatic static = do
  rtable <- remoteTable . processNode <$> ask
  case Static.unstatic rtable static of
    Left err -> fail $ "Could not resolve static value: " ++ err
    Right x  -> return x

-- | Resolve a closure
unClosure :: Typeable a => Closure a -> Process a
unClosure closure = do
  rtable <- remoteTable . processNode <$> ask
  case Static.unclosure rtable closure of
    Left err -> fail $ "Could not resolve closure: " ++ err
    Right x  -> return x

--------------------------------------------------------------------------------
-- Reconnecting                                                               --
--------------------------------------------------------------------------------

-- | Cloud Haskell provides the illusion of connection-less, reliable, ordered
-- message passing. However, when network connections get disrupted this
-- illusion cannot always be maintained. Once a network connection breaks (even
-- temporarily) no further communication on that connection will be possible.
-- For example, if process A sends a message to process B, and A is then
-- notified (by monitor notification) that it got disconnected from B, A will
-- not be able to send any further messages to B, /unless/ A explicitly
-- indicates that it is acceptable to attempt to reconnect to B using the
-- Cloud Haskell 'reconnect' primitive.
--
-- Importantly, when A calls 'reconnect' it acknowledges that some messages to
-- B might have been lost. For instance, if A sends messages m1 and m2 to B,
-- then receives a monitor notification that its connection to B has been lost,
-- calls 'reconnect' and then sends m3, it is possible that B will receive m1
-- and m3 but not m2.
--
-- Note that 'reconnect' does not mean /reconnect now/ but rather /it is okay
-- to attempt to reconnect on the next send/. In particular, if no further
-- communication attempts are made to B then A can use reconnect to clean up
-- its connection to B.
reconnect :: ProcessId -> Process ()
reconnect them = do
  us <- getSelfPid
  node <- processNode <$> ask
  liftIO $ disconnect node (ProcessIdentifier us) (ProcessIdentifier them)

-- | Reconnect to a sendport. See 'reconnect' for more information.
reconnectPort :: SendPort a -> Process ()
reconnectPort them = do
  us <- getSelfPid
  node <- processNode <$> ask
  liftIO $ disconnect node (ProcessIdentifier us) (SendPortIdentifier (sendPortId them))

--------------------------------------------------------------------------------
-- Auxiliary functions                                                        --
--------------------------------------------------------------------------------

getMonitorRefFor :: Identifier -> Process MonitorRef
getMonitorRefFor ident = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do
    let counter = st ^. monitorCounter
    return ( monitorCounter ^: (+ 1) $ st
           , MonitorRef ident counter
           )

getSpawnRef :: Process SpawnRef
getSpawnRef = do
  proc <- ask
  liftIO $ modifyMVar (processState proc) $ \st -> do
    let counter = st ^. spawnCounter
    return ( spawnCounter ^: (+ 1) $ st
           , SpawnRef counter
           )

-- | Monitor a process/node/channel
monitor' :: Identifier -> Process MonitorRef
monitor' ident = do
  monitorRef <- getMonitorRefFor ident
  sendCtrlMsg Nothing $ Monitor monitorRef
  return monitorRef

-- | Link to a process/node/channel
link' :: Identifier -> Process ()
link' = sendCtrlMsg Nothing . Link

-- Send a control message
sendCtrlMsg :: Maybe NodeId  -- ^ Nothing for the local node
            -> ProcessSignal -- ^ Message to send
            -> Process ()
sendCtrlMsg mNid signal = do
  proc <- ask
  let msg = NCMsg { ctrlMsgSender = ProcessIdentifier (processId proc)
                  , ctrlMsgSignal = signal
                  }
  case mNid of
    Nothing -> do
      liftIO $ writeChan (localCtrlChan (processNode proc)) msg
    Just nid ->
      liftIO $ sendBinary (processNode proc)
                          (ProcessIdentifier (processId proc))
                          (NodeIdentifier nid)
                          WithImplicitReconnect
                          msg
