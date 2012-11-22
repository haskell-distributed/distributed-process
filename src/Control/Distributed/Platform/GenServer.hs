{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

-- | Second iteration of GenServer
module Control.Distributed.Platform.GenServer (
    Name,
    ServerId,
    Timeout(..),
    InitResult(..),
    CallResult(..),
    CastResult(..),
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
    stopServer
  ) where

import           Control.Distributed.Process              (AbstractMessage (forward),
                                                           Match, MonitorRef,
                                                           Process, ProcessId,
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

-- | Process name
type Name = String

-- | ServerId
type ServerId = ProcessId

-- | Timeout
data Timeout = Timeout Int
             | NoTimeout

-- | Initialize handler result
data InitResult
  = InitOk Timeout
  | InitStop String


-- | Terminate reason
data TerminateReason
  = TerminateNormal
  | TerminateShutdown
  | TerminateReason String
    deriving (Show, Typeable)
$(derive makeBinary ''TerminateReason)



-- | Server monad
type Server s = ST.StateT s Process



-- | Handlers
type InitHandler s           = Server s InitResult
type TerminateHandler s       = TerminateReason -> Server s ()
type CallHandler s a b        = a -> Server s (CallResult b)
type CastHandler s a          = a -> Server s CastResult



-- | The result of a call
data CallResult a
    = CallOk a
    | CallForward ServerId
    | CallStop a String
        deriving (Show, Typeable)



-- | The result of a cast
data CastResult
    = CastOk
    | CastForward ServerId
    | CastStop String




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
data MessageDispatcher s
  = forall a . (Serializable a) => MessageDispatcher {
        dispatcher :: s -> Message a -> Process s
      }
  | forall a . (Serializable a) => MessageDispatcherIf {
        dispatcher :: s -> Message a -> Process s,
        dispatchIf :: s -> Message a -> Bool
      }
  | MessageDispatcherAny {
        dispatcherAny :: s -> AbstractMessage -> Process s
      }


-- | Matches messages using a dispatcher
class MessageMatcher d where
    matchMessage :: s -> d s -> Match s


-- | Matches messages to a MessageDispatcher
instance MessageMatcher MessageDispatcher where
  matchMessage state (MessageDispatcher dispatcher) = match (dispatcher state)
  matchMessage state (MessageDispatcherIf dispatcher cond) = matchIf (cond state) (dispatcher state)
  matchMessage state (MessageDispatcherAny dispatcher) = matchAny (dispatcher state)

-- | Constructs a call message dispatcher
--
handleCall :: (Serializable a, Show a, Serializable b) => CallHandler s a b -> MessageDispatcher s
handleCall handler = handleCallIf (const True) handler

handleCallIf :: (Serializable a, Show a, Serializable b) => (a -> Bool) -> CallHandler s a b -> MessageDispatcher s
handleCallIf cond handler = MessageDispatcherIf {
  dispatcher = (\state m@(Message cid req) -> do
      say $ "Server got CALL: " ++ show m
      (result, state') <- ST.runStateT (handler req) state
      case result of
          CallOk resp -> send cid resp
          CallForward sid -> send sid m
          CallStop resp reason -> return ()
      return state'
  ),
  dispatchIf = \state (Message _ req) -> cond req
}

-- | Constructs a cast message dispatcher
--
handleCast :: (Serializable a, Show a) => CastHandler s a -> MessageDispatcher s
handleCast = handleCastIf (const True)


-- |
handleCastIf :: (Serializable a, Show a) => (a -> Bool) -> CastHandler s a -> MessageDispatcher s
handleCastIf cond handler = MessageDispatcherIf {
  dispatcher = (\state m@(Message cid msg) -> do
      say $ "Server got CAST: " ++ show m
      (result, state') <- ST.runStateT (handler msg) state
      case result of
          CastOk -> return state'
          CastForward sid -> do
            send sid m
            return state'
          CastStop reason -> error "TODO"
  ),
  dispatchIf = \state (Message _ msg) -> cond msg
}

-- | Constructs a dispatcher for any message
-- Note that since we don't know the type of this message it assumes the protocol of a cast
-- i.e. no reply's
handleAny :: (AbstractMessage -> Server s (CastResult)) -> MessageDispatcher s
handleAny handler = MessageDispatcherAny {
  dispatcherAny = (\state m -> do
      (result, state') <- ST.runStateT (handler m) state
      case result of
          CastOk -> return state'
          CastForward sid -> do
            (forward m) sid
            return state'
          CastStop reason -> error "TODO"
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
  ST.runStateT (processServer handlers) state
  return ()

-- TODO
startServerLink :: s -> LocalServer s -> Process (ServerId, MonitorRef)
startServerLink handlers = undefined
  --us   <- getSelfPid
  --them <- spawn nid (cpLink us `seqCP` proc)
  --ref  <- monitor them
  --return (them, ref)

-- | call a server identified by it's ServerId
callServer :: (Serializable rq, Serializable rs) => ServerId -> Timeout -> rq -> Process rs
callServer sid timeout rq = do
  cid <- getSelfPid
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
    ST.lift $ say $ "Server initializing ... "
    ir <- initHandler localServer
    return ir

-- | server loop
processLoop :: LocalServer s -> Timeout -> Server s TerminateReason
processLoop localServer timeout = do
    mayMsg <- processReceive (msgHandlers localServer) timeout
    case mayMsg of
        Just reason -> return reason
        Nothing -> processLoop localServer timeout

-- |
processReceive :: [MessageDispatcher s] -> Timeout -> Server s (Maybe TerminateReason)
processReceive ds timeout = do
    state <- ST.get
    case timeout of
        NoTimeout -> do
            state <- ST.lift $ receiveWait $ map (matchMessage state) ds
            putState state
            return Nothing
        Timeout time -> do
            mayResult <- ST.lift $ receiveTimeout time $ map (matchMessage state) ds
            case mayResult of
                Just state -> do
                  putState state
                  return Nothing
                Nothing -> do
                    trace "Receive timed out ..."
                    return $ Just (TerminateReason "Receive timed out")

-- | terminate server
processTerminate :: LocalServer s -> TerminateReason -> Server s ()
processTerminate localServer reason = do
    trace $ "Server terminating ... "
    (terminateHandler localServer) reason

-- | Log a trace message using the underlying Process's say
trace :: String -> Server s ()
trace msg = ST.lift . say $ msg
