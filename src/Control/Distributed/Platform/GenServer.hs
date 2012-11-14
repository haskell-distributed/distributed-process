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

--type Server s = StateT s Process

-- | Handlers
type InitHandler            = Process InitResult
type TerminateHandler       = TerminateReason -> Process ()
type CallHandler a b        = a -> Process (CallResult b)
type CastHandler a          = a -> Process CastResult

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

-- | General idea of a future here
-- This should hook up into the receive loop to update the result MVar automatically without blocking the server
-- data Future a = Future { result :: MVar (Either IOError a) }


-- | Adds routing metadata to the actual payload
data Message a = Message ProcessId a
    deriving (Show, Typeable)
$(derive makeBinary ''Message)

-- | Management message
-- TODO is there a std way of terminating a process from another process?
data ManageServer = TerminateServer TerminateReason
  deriving (Show, Typeable)
$(derive makeBinary ''ManageServer)


-- | Matches messages using a dispatcher
class MessageMatcher d where
    matchMessage :: d -> Match ()

-- | Dispatcher that knows how to dispatch messages to a handler
data MessageDispatcher
  = forall a . (Serializable a) => MessageDispatcher { dispatcher :: Message a -> Process () }
  | forall a . (Serializable a) => MessageDispatcherIf { dispatcher :: Message a -> Process (), dispatchIf :: Message a -> Bool }
  | MessageDispatcherAny { dispatcherAny :: AbstractMessage -> Process () }


-- | Matches messages to a MessageDispatcher
instance MessageMatcher MessageDispatcher where
  matchMessage (MessageDispatcher d) = match d
  matchMessage (MessageDispatcherIf d c) = matchIf c d
  matchMessage (MessageDispatcherAny d) = matchAny d

-- | Constructs a call message dispatcher
--
handleCall :: (Serializable a, Show a, Serializable b) => CallHandler a b -> MessageDispatcher
handleCall = handleCallIf (const True)

handleCallIf :: (Serializable a, Show a, Serializable b) => (a -> Bool) -> CallHandler a b -> MessageDispatcher
handleCallIf pred handler = MessageDispatcherIf {
  dispatcher = (\m@(Message cid req) -> do
      say $ "Server got CALL: " ++ show m
      result <- handler req
      case result of
          CallOk resp -> send cid resp
          CallForward sid -> send sid m
          CallStop resp reason -> return ()
  ),
  dispatchIf = \(Message _ req) -> pred req
}

-- | Constructs a cast message dispatcher
--
handleCast :: (Serializable a, Show a) => CastHandler a -> MessageDispatcher
handleCast = handleCastIf (const True)

handleCastIf :: (Serializable a, Show a) => (a -> Bool) -> CastHandler a -> MessageDispatcher
handleCastIf pred handler = MessageDispatcherIf {
  dispatcher = (\m@(Message cid msg) -> do
      say $ "Server got CAST: " ++ show m
      result <- handler msg
      case result of
          CastOk -> return ()
          CastForward sid -> send sid m
          CastStop reason -> error "TODO"
  ),
  dispatchIf = \(Message _ msg) -> pred msg
}

-- | Constructs a dispatcher for any message
-- Note that since we don't know the type of this message it assumes the protocol of a cast
-- i.e. no reply's
handleAny :: (AbstractMessage -> Process (CastResult)) -> MessageDispatcher
handleAny handler = MessageDispatcherAny {
  dispatcherAny = (\m -> do
      result <- handler m
      case result of
          CastOk -> return ()
          CastForward sid -> (forward m) sid
          CastStop reason -> error "TODO"
  )
}

-- | The server callbacks
data LocalServer = LocalServer {
    initHandler      :: InitHandler,        -- ^ initialization handler
    msgHandlers      :: [MessageDispatcher],
    terminateHandler :: TerminateHandler    -- ^ termination handler
  }

---- | Default record
---- Starting point for creating new servers
defaultServer :: LocalServer
defaultServer = LocalServer {
  initHandler = return $ InitOk NoTimeout,
  msgHandlers = [],
  terminateHandler = \_ -> return ()
}

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Start a new server and return it's id
startServer :: LocalServer -> Process ServerId
startServer handlers = spawnLocal $ processServer handlers

-- TODO
startServerLink :: LocalServer -> Process (ServerId, MonitorRef)
startServerLink handlers = undefined
  --us   <- getSelfPid
  --them <- spawn nid (cpLink us `seqCP` proc)
  --ref  <- monitor them
  --return (them, ref)

-- | call a server identified by it's ServerId
callServer :: (Serializable rq, Serializable rs) => ServerId -> rq -> Timeout -> Process rs
callServer sid rq timeout = do
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

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | server process
processServer :: LocalServer -> Process ()
processServer localServer = do
    ir <- processInit localServer
    tr <- case ir of
            InitOk to -> do
              say $ "Server ready to receive messages!"
              processLoop localServer to
            InitStop r -> return (TerminateReason r)
    processTerminate localServer tr

-- | initialize server
processInit :: LocalServer -> Process InitResult
processInit localServer = do
    say $ "Server initializing ... "
    ir <- initHandler localServer
    return ir

-- | server loop
processLoop :: LocalServer -> Timeout -> Process TerminateReason
processLoop localServer timeout = do
    mayMsg <- processReceive (msgHandlers localServer) timeout
    case mayMsg of
        Just reason -> return reason
        Nothing -> processLoop localServer timeout

-- |
processReceive :: [MessageDispatcher] -> Timeout -> Process (Maybe TerminateReason)
processReceive ds timeout = do
    case timeout of
        NoTimeout -> do
            receiveWait $ map matchMessage ds
            return Nothing
        Timeout time -> do
            mayResult <- receiveTimeout time $ map matchMessage ds
            case mayResult of
                Just _ -> return Nothing
                Nothing -> do
                    say "Receive timed out ..."
                    return Nothing

-- | terminate server
processTerminate :: LocalServer -> TerminateReason -> Process ()
processTerminate localServer reason = do
    say $ "Server terminating ... "
    (terminateHandler localServer) reason
