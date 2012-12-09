{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

-- | Second iteration of GenServer
module Control.Distributed.Platform.GenServer (
    ServerId,
    Timeout(..),
    initOk,
    initStop,
    callOk,
    callForward,
    callStop,
    castOk,
    castForward,
    castStop,
    TerminateReason(..),
    InitHandler,
    TerminateHandler,
    MessageDispatcher(),
    handleCall,
    handleCallIf,
    handleCast,
    handleCastIf,
    handleAny,
    putState,
    getState,
    modifyState,
    LocalServer(..),
    defaultServer,
    startServer,
    callServer,
    castServer,
    stopServer,
    Process,
    trace
  ) where

import           Control.Distributed.Process              (AbstractMessage (forward),
                                                           Match,
                                                           Process,
                                                           ProcessId,
                                                           expect,
                                                           expectTimeout,
                                                           getSelfPid, match,
                                                           matchAny, matchIf,
                                                           receiveTimeout,
                                                           receiveWait, say,
                                                           send, spawnLocal)
import           Control.Distributed.Process.Serializable (Serializable)
import qualified Control.Monad.State                      as ST (StateT,
                                                                 get, lift,
                                                                 modify, put,
                                                                 runStateT)

import           Data.Binary                              (Binary (..),
                                                           getWord8, putWord8)
import           Data.DeriveTH
import           Data.Typeable                            (Typeable)


--------------------------------------------------------------------------------
-- Data Types                                                                 --
--------------------------------------------------------------------------------

-- | ServerId
type ServerId = ProcessId

-- | Timeout
data Timeout = Timeout Int
             | NoTimeout

-- | Server monad
type Server s = ST.StateT s Process

-- | Initialize handler result
data InitResult
  = InitOk Timeout
  | InitStop String

initOk :: Timeout -> Server s InitResult
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
data CallResult a
    = CallOk a
    | CallForward ServerId
    | CallStop a String
        deriving (Show, Typeable)

callOk :: a -> Server s (CallResult a)
callOk resp = return (CallOk resp)

callForward :: ServerId -> Server s (CallResult a)
callForward sid = return (CallForward sid)

callStop :: a -> String -> Server s (CallResult a)
callStop resp reason = return (CallStop resp reason)

-- | The result of a cast
data CastResult
    = CastOk
    | CastForward ServerId
    | CastStop String

castOk :: Server s CastResult
castOk = return CastOk

castForward :: ServerId -> Server s CastResult
castForward sid = return (CastForward sid)

castStop :: String -> Server s CastResult
castStop reason = return (CastStop reason)

-- | Handlers
type InitHandler s           = Server s InitResult
type TerminateHandler s       = TerminateReason -> Server s ()
type CallHandler s a b        = a -> Server s (CallResult b)
type CastHandler s a          = a -> Server s CastResult

-- | Adds routing metadata to the actual payload
data Message a = Message ProcessId a
    deriving (Show, Typeable)
$(derive makeBinary ''Message)

-- | Management message
-- TODO is there a std way of terminating a process from another process?
data ManageServer = TerminateServer TerminateReason
  deriving (Show, Typeable)
$(derive makeBinary ''ManageServer)

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
handleCall :: (Serializable a, Show a, Serializable b) => CallHandler s a b -> MessageDispatcher s
handleCall = handleCallIf (const True)

handleCallIf :: (Serializable a, Show a, Serializable b) => (a -> Bool) -> CallHandler s a b -> MessageDispatcher s
handleCallIf cond handler = MessageDispatcherIf {
  dispatcher = (\state m@(Message cid req) -> do
      say $ "Server got CALL: [" ++ show cid ++ " / " ++ show req ++ "]"
      (r, s') <- ST.runStateT (handler req) state
      case r of
          CallOk resp -> do
            send cid resp
            return (s', Nothing)
          CallForward sid -> do
            send sid m
            return (s', Nothing)
          CallStop resp reason -> do
            send cid resp
            return (s', Just (TerminateReason reason))
  ),
  dispatchIf = \_ (Message _ req) -> cond req
}

-- | Constructs a cast message dispatcher
--
handleCast :: (Serializable a, Show a) => CastHandler s a -> MessageDispatcher s
handleCast = handleCastIf (const True)

-- |
handleCastIf :: (Serializable a, Show a) => (a -> Bool) -> CastHandler s a -> MessageDispatcher s
handleCastIf cond handler = MessageDispatcherIf {
  dispatcher = (\s m@(Message cid msg) -> do
      say $ "Server got CAST: [" ++ show cid ++ " / " ++ show msg ++ "]"
      (r, s') <- ST.runStateT (handler msg) s
      case r of
          CastStop reason -> return (s', Just $ TerminateReason reason)
          CastOk -> return (s', Nothing)
          CastForward sid -> do
            send sid m
            return (s', Nothing)
  ),
  dispatchIf = \_ (Message _ msg) -> cond msg
}

-- | Constructs a dispatcher for any message
-- Note that since we don't know the type of this message it assumes the protocol of a cast
-- i.e. no reply's
handleAny :: (AbstractMessage -> Server s (CastResult)) -> MessageDispatcher s
handleAny handler = MessageDispatcherAny {
  dispatcherAny = (\s m -> do
      (r, s') <- ST.runStateT (handler m) s
      case r of
          CastStop reason -> return (s', Just $ TerminateReason reason)
          CastOk -> return (s', Nothing)
          CastForward sid -> do
            (forward m) sid
            return (s', Nothing)
  )
}

-- | The server callbacks
data LocalServer s = LocalServer {
    initHandler      :: InitHandler s,        -- ^ initialization handler
    msgHandlers      :: [MessageDispatcher s],
    terminateHandler :: TerminateHandler s   -- ^ termination handler
  }

---- | Default record
---- Starting point for creating new servers
defaultServer :: LocalServer s
defaultServer = LocalServer {
  initHandler = return $ InitOk NoTimeout,
  msgHandlers = [],
  terminateHandler = \_ -> return ()
}

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Start a new server and return it's id
startServer :: s -> LocalServer s -> Process ServerId
startServer state handlers = spawnLocal $ do
  _ <- ST.runStateT (processServer handlers) state
  return ()

-- | call a server identified by it's ServerId
callServer :: (Serializable rq, Serializable rs) => ServerId -> Timeout -> rq -> Process rs
callServer sid timeout rq = do
  cid <- getSelfPid
  say $ "Calling server " ++ show cid
  send sid (Message cid rq)
  case timeout of
    NoTimeout -> expect
    Timeout time -> do
      mayResp <- expectTimeout time
      case mayResp of
        Just msg -> return msg
        Nothing -> error $ "timeout! value = " ++ show time

-- | Cast a message to a server identified by it's ServerId
castServer :: (Serializable a) => ServerId -> a -> Process ()
castServer sid msg = do
  cid <- getSelfPid
  say $ "Casting server " ++ show cid
  send sid (Message cid msg)

-- | Stops a server identified by it's ServerId
stopServer :: ServerId -> TerminateReason -> Process ()
stopServer sid reason = castServer sid (TerminateServer reason)

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
processServer :: LocalServer s -> Server s ()
processServer localServer = do
    ir <- processInit localServer
    tr <- case ir of
            InitOk to -> do
              trace $ "Server ready to receive messages!"
              processLoop localServer to
            InitStop r -> return (TerminateReason r)
    processTerminate localServer tr

-- | initialize server
processInit :: LocalServer s -> Server s InitResult
processInit localServer = do
    trace $ "Server initializing ... "
    ir <- initHandler localServer
    return ir

-- | server loop
processLoop :: LocalServer s -> Timeout -> Server s TerminateReason
processLoop localServer t = do
    mayMsg <- processReceive (msgHandlers localServer) t
    case mayMsg of
        Just r -> return r
        Nothing -> processLoop localServer t

-- |
processReceive :: [MessageDispatcher s] -> Timeout -> Server s (Maybe TerminateReason)
processReceive ds timeout = do
    s <- getState
    let ms = map (matchMessage s) ds
    case timeout of
        NoTimeout -> do
            (s', r) <- ST.lift $ receiveWait ms
            putState s'
            return r
        Timeout t -> do
            mayResult <- ST.lift $ receiveTimeout t ms
            case mayResult of
                Just (s', r) -> do
                  putState s'
                  return r
                Nothing -> do
                  trace "Receive timed out ..."
                  return $ Just (TerminateReason "Receive timed out")

-- | terminate server
processTerminate :: LocalServer s -> TerminateReason -> Server s ()
processTerminate localServer reason = do
    trace $ "Server terminating: " ++ show reason
    (terminateHandler localServer) reason

-- | Log a trace message using the underlying Process's say
trace :: String -> Server s ()
trace msg = ST.lift . say $ msg
