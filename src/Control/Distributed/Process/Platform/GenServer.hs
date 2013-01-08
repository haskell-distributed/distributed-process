{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

-- | Second iteration of GenServer
module Control.Distributed.Process.Platform.GenServer (
    ServerId,
    Timeout(..),
    initOk,
    initStop,
    ok,
    forward,
    stop,
    InitHandler,
    Handler,
    TerminateHandler,
    MessageDispatcher(),
    handle,
    handleIf,
    handleAny,
    putState,
    getState,
    modifyState,
    LocalServer(..),
    defaultServer,
    start,
    startLink,
    startMonitor,
    terminate,
    cast,
    Async(),
    call,
    callTimeout,
    callAsync,
    wait,
    waitTimeout,
    Process,
    trace
  ) where

import qualified Control.Distributed.Process as P (forward, catch)
import qualified Control.Monad.State as ST (MonadState,
                                            MonadTrans,
                                            StateT, get,
                                            lift, modify,
                                            put,
                                            runStateT)

import Control.Applicative (Applicative)
import Control.Exception (SomeException)
import Control.Monad.IO.Class (MonadIO)

import Control.Distributed.Process (AbstractMessage,
                                    Match,
                                    Process,
                                    ProcessId,
                                    expectTimeout,
                                    monitor, unmonitor,
                                    link, finally,
                                    exit, getSelfPid, match,
                                    matchAny, matchIf,
                                    receiveTimeout,
                                    receiveWait, say,
                                    send, spawnLocal,
                                    ProcessMonitorNotification(..))

import Control.Distributed.Process.Internal.Types (MonitorRef)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Async

import Data.Binary (Binary (..), getWord8, putWord8)
import Data.Maybe (fromJust)
import Data.DeriveTH
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- Data Types                                                                 --
--------------------------------------------------------------------------------

-- | ServerId
type ServerId = ProcessId

-- | Server monad
newtype Server s a = Server {
    unServer :: ST.StateT s Process a
  }
  deriving (Functor, Monad, ST.MonadState s, MonadIO, Typeable, Applicative)

-- | Initialize handler result
data InitResult
  = InitOk Delay
  | InitStop String

initOk :: Delay -> Server s InitResult
initOk t = return (InitOk t)

initStop :: String -> Server s InitResult
initStop reason = return (InitStop reason)

-- | Terminate reason
data TerminateReason
  = TerminateNormal
  | TerminateShutdown
  | TerminateReason String
    deriving (Show, Typeable)
$(derive makeBinary ''TerminateReason)

-- | The result of a call
data Result a
    = Ok a
    | Forward ServerId
    | Stop a String
        deriving (Show, Typeable)

ok :: (Serializable a, Show a) => a -> Server s (Result a)
ok resp = return (Ok resp)

forward :: (Serializable a, Show a) => ServerId -> Server s (Result a)
forward sid = return (Forward sid)

stop :: (Serializable a, Show a) => a -> String -> Server s (Result a)
stop resp reason = return (Stop resp reason)

-- | Handlers
type InitHandler s       = Server s InitResult
type TerminateHandler s  = TerminateReason -> Server s ()
type Handler s a b       = a -> Server s (Result b)

-- | Adds routing metadata to the actual payload
data Message a =
    CallMessage { msgFrom :: ProcessId, msgPayload :: a }
  | CastMessage { msgFrom :: ProcessId, msgPayload :: a }
    deriving (Show, Typeable)
$(derive makeBinary ''Message)

-- | Dispatcher that knows how to dispatch messages to a handler
-- s The server state
data MessageDispatcher s =
    forall a . (Serializable a) => MessageDispatcher {
        dispatcher :: s -> Message a -> Process (s, Maybe TerminateReason)
      }
  | forall a . (Serializable a) => MessageDispatcherIf {
        dispatcher :: s -> Message a -> Process (s, Maybe TerminateReason),
        dispatchIf :: s -> Message a -> Bool
      }
  | MessageDispatcherAny {
        dispatcherAny :: s -> AbstractMessage -> Process (s, Maybe TerminateReason)
      }

-- | Matches messages using a dispatcher
class MessageMatcher d where
    matchMessage :: s -> d s -> Match (s, Maybe TerminateReason)

-- | Matches messages to a MessageDispatcher
instance MessageMatcher MessageDispatcher where
  matchMessage s (MessageDispatcher    d)      = match (d s)
  matchMessage s (MessageDispatcherIf  d cond) = matchIf (cond s) (d s)
  matchMessage s (MessageDispatcherAny d)      = matchAny (d s)

-- | Constructs a call message dispatcher
--
handle :: (Serializable a, Show a, Serializable b, Show b) => Handler s a b -> MessageDispatcher s
handle = handleIf (const True)

handleIf :: (Serializable a, Show a, Serializable b, Show b) => (a -> Bool) -> Handler s a b -> MessageDispatcher s
handleIf cond handler = MessageDispatcherIf {
  dispatcher = (\s msg -> case msg of
    CallMessage cid payload -> do
      --say $ "Server got CALL: [" ++ show cid ++ " / " ++ show payload ++ "]"
      (r, s') <- runServer (handler payload) s
      case r of
          Ok resp -> do
            --say $ "Server REPLY: " ++ show r
            send cid resp
            return (s', Nothing)
          Forward sid -> do
            --say $ "Server FORWARD to: " ++ show sid
            send sid msg
            return (s', Nothing)
          Stop resp reason -> do
            --say $ "Server REPLY: " ++ show r
            send cid resp
            return (s', Just (TerminateReason reason))
    CastMessage _ payload -> do
      --say $ "Server got CAST: [" ++ show cid ++ " / " ++ show payload ++ "]"
      (r, s') <- runServer (handler payload) s
      case r of
          Stop _ reason -> return (s', Just $ TerminateReason reason)
          Ok _ -> return (s', Nothing)
          Forward sid -> do
            send sid msg
            return (s', Nothing)
  ),
  dispatchIf = \_ msg -> cond (msgPayload msg)
}

-- | Constructs a dispatcher for any message
-- Note that since we don't know the type of this message it assumes the protocol of a cast
-- i.e. no reply's
handleAny :: (Serializable a, Show a) => (AbstractMessage -> Server s (Result a)) -> MessageDispatcher s
handleAny handler = MessageDispatcherAny {
  dispatcherAny = (\s m -> do
      (r, s') <- runServer (handler m) s
      case r of
          Stop _ reason -> return (s', Just $ TerminateReason reason)
          Ok _ -> return (s', Nothing)
          Forward sid -> do
            (P.forward m) sid
            return (s', Nothing)
  )
}

-- | The server callbacks
data LocalServer s = LocalServer {
    initHandler      :: InitHandler s,        -- ^ initialization handler
    handlers         :: [MessageDispatcher s],
    terminateHandler :: TerminateHandler s   -- ^ termination handler
  }

---- | Default record
---- Starting point for creating new servers
defaultServer :: LocalServer s
defaultServer = LocalServer {
  initHandler       = return $ InitOk Infinity,
  handlers          = [],
  terminateHandler  = \_ -> return ()
}

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Start a new server and return it's id
start :: s -> LocalServer s -> Process ServerId
start s ls = spawnLocal proc
  where
    proc = processServer initH terminateH hs s
    initH = initHandler ls
    terminateH = terminateHandler ls
    hs = handlers ls

-- | Spawn a process and link to it
startLink :: s -> LocalServer s -> Process ServerId
startLink s ls = do
  pid <- start s ls
  link pid
  return pid

-- | Like 'spawnServerLink', but monitor the spawned process
startMonitor :: s -> LocalServer s -> Process (ServerId, MonitorRef)
startMonitor s ls = do
  pid <- start s ls
  ref <- monitor pid
  return (pid, ref)

-- | Sync call with no timeout
call :: (Serializable rq, Show rq, Serializable rs, Show rs) => ServerId -> rq -> Process rs
call sid rq = callTimeout sid Infinity rq >>= return . fromJust

-- | Sync call
callTimeout :: (Serializable rq, Show rq, Serializable rs, Show rs) => ServerId -> Delay -> rq -> Process (Maybe rs)
callTimeout sid t rq = do
  a1 <- callAsync sid rq
  waitTimeout a1 t

-- | Async call to a server
callAsync :: (Serializable rq, Show rq, Serializable rs, Show rs) => ServerId -> rq -> Process (Async rs)
callAsync sid rq = async sid $ do
  cid <- getSelfPid
  --say $ "Calling server " ++ show cid ++ " - " ++ show rq
  send sid (CallMessage cid rq)

-- | Cast a message to a server identified by it's ServerId
cast :: (Serializable a) => ServerId -> a -> Process ()
cast sid msg = do
  cid <- getSelfPid
  --say $ "Casting server " ++ show cid
  send sid (CastMessage cid msg)

-- | Stops a server identified by it's ServerId
terminate :: Serializable a => ServerId -> a -> Process ()
terminate sid reason = do
  --say $ "Stop server " ++ show sid
  exit sid reason

-- | Get the server state
getState :: Server s s
getState = ST.get

-- | Put the server state
putState :: s -> Server s ()
putState = ST.put

-- | Modify the server state
modifyState :: (s -> s) -> Server s ()
modifyState = ST.modify

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | server process
processServer :: InitHandler s -> TerminateHandler s -> [MessageDispatcher s] -> s -> Process ()
processServer initH terminateH dispatchers s = do
    (ir, s')    <- runServer initH s
    P.catch (proc ir s') (exitHandler s')
  where
    proc ir s' = do
      (tr, s'')   <- runServer (processLoop dispatchers ir)     s'
      _           <- runServer (terminateH tr) s''
      return ()
    exitHandler s' e = do
      let tr = TerminateReason $ show (e :: SomeException)
      _     <- runServer (terminateH tr) s'
      return ()

-- | server loop
processLoop :: [MessageDispatcher s] -> InitResult -> Server s TerminateReason
processLoop dispatchers ir = do
    case ir of
      InitOk t -> loop dispatchers t
      InitStop r -> return $ TerminateReason r
  where
    loop ds t = do
        msgM <- processReceive ds t
        case msgM of
            Nothing -> loop ds t
            Just r -> return r

-- |
processReceive :: [MessageDispatcher s] -> Delay -> Server s (Maybe TerminateReason)
processReceive ds timeout = do
    s <- getState
    let ms = map (matchMessage s) ds
    case timeout of
        Infinity -> do
            (s', r) <- lift $ receiveWait ms
            putState s'
            return r
        Delay t -> do
            mayResult <- lift $ receiveTimeout (intervalToMs t) ms
            case mayResult of
                Just (s', r) -> do
                  putState s'
                  return r
                Nothing -> do
                  --trace "Receive timed out ..."
                  return $ Just (TerminateReason "Receive timed out")

-- | Log a trace message using the underlying Process's say
trace :: String -> Server s ()
trace msg = lift . say $ msg

-- | TODO MonadTrans instance? lift :: (Monad m) => m a -> t m a
lift :: Process a -> Server s a
lift p = Server $ ST.lift p

-- |
runServer :: Server s a -> s -> Process (a, s)
runServer server state = ST.runStateT (unServer server) state
