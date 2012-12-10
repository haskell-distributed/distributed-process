{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FunctionalDependencies    #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

module Control.Distributed.Platform.GenProcess where

-- TODO: define API and hide internals...

import qualified Control.Distributed.Process as BaseProcess
import qualified Control.Monad.State         as ST (StateT, get,
                                                    lift, modify,
                                                    put, runStateT)

import Control.Distributed.Process.Serializable
import Control.Distributed.Platform.Internal.Types
import Control.Distributed.Platform.Timer          (intervalToMs)
import Data.Binary
import Data.DeriveTH
import Data.Typeable                               (Typeable)
import Prelude                                     hiding (init)


type ServerName = String
type ServerPid  = BaseProcess.ProcessId

data ServerId = ServerProcess ServerPid | NamedServer ServerName

data Recipient a = SendToPid BaseProcess.ProcessId |
                   SendToPort (BaseProcess.SendPort a)

-- | Initialize handler result
data InitResult =
    InitOk Timeout
  | InitStop String

-- | Terminate reason
data TerminateReason =
    TerminateNormal
  | TerminateShutdown
  | TerminateReason String
    deriving (Show, Typeable)
$(derive makeBinary ''TerminateReason)

data ReplyTo = ReplyTo BaseProcess.ProcessId | None
    deriving (Typeable, Show)
$(derive makeBinary ''ReplyTo)

-- | The result of a call
data ProcessAction =
    ProcessContinue
  | ProcessTimeout Timeout
  | ProcessStop String
    deriving (Typeable)
$(derive makeBinary ''ProcessAction)

type Process s = ST.StateT s BaseProcess.Process

-- | Handlers
type InitHandler      s   = Process s InitResult
type TerminateHandler s   = TerminateReason -> Process s ()
type RequestHandler   s a = Message a -> Process s ProcessAction

-- | Contains the actual payload and possibly additional routing metadata
data Message a = Message ReplyTo a
    deriving (Show, Typeable)
$(derive makeBinary ''Message)

data Rpc a b = ProcessRpc (Message a) b | PortRpc a (BaseProcess.SendPort b)
    deriving (Typeable)
$(derive makeBinary ''Rpc) 

-- | Dispatcher that knows how to dispatch messages to a handler
data Dispatcher s =
  forall a . (Serializable a) =>
    Dispatch    { dispatch  :: s -> Message a ->
                               BaseProcess.Process (s, ProcessAction) } |
  forall a . (Serializable a) =>
    DispatchIf  { dispatch  :: s -> Message a ->
                               BaseProcess.Process (s, ProcessAction),
                  condition :: s -> Message a -> Bool }

-- dispatching to implementation callbacks

-- | Matches messages using a dispatcher
class Dispatchable d where
    matchMessage :: s -> d s -> BaseProcess.Match (s, ProcessAction)

-- | Matches messages to a MessageDispatcher
instance Dispatchable Dispatcher where
  matchMessage s (Dispatch   d  ) = BaseProcess.match (d s)
  matchMessage s (DispatchIf d c) = BaseProcess.matchIf (c s) (d s)


data Behaviour s = Behaviour {
    initHandler      :: InitHandler s        -- ^ initialization handler
  , dispatchers      :: [Dispatcher s]
  , terminateHandler :: TerminateHandler s    -- ^ termination handler
    }

-- | Management message
-- TODO is there a std way of terminating a process from another process?
data Termination = Terminate TerminateReason
    deriving (Show, Typeable)
$(derive makeBinary ''Termination)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Start a new server and return it's id
-- start :: Behaviour s -> Process ProcessId
-- start handlers = spawnLocal $ runProcess handlers

reply :: (Serializable m) => ReplyTo -> m -> BaseProcess.Process ()
reply (ReplyTo pid) m = BaseProcess.send pid m
reply _             _ = return ()

replyVia :: (Serializable m) => BaseProcess.SendPort m -> m ->
                                BaseProcess.Process ()
replyVia p m = BaseProcess.sendChan p m

-- | Given a state, behaviour specificiation and spawn function,
-- starts a new server and return its id. The spawn function is typically
-- one taken from "Control.Distributed.Process".
-- see 'Control.Distributed.Process.spawn'
--     'Control.Distributed.Process.spawnLocal' 
--     'Control.Distributed.Process.spawnLink'
--     'Control.Distributed.Process.spawnMonitor'
--     'Control.Distributed.Process.spawnSupervised' 
start ::
  s -> Behaviour s ->
  (BaseProcess.Process () -> BaseProcess.Process BaseProcess.ProcessId) ->
  BaseProcess.Process BaseProcess.ProcessId
start state handlers spawn = spawn $ do
  _ <- ST.runStateT (runProc handlers) state
  return ()

send :: (Serializable m) => ServerId -> m -> BaseProcess.Process ()
send s m = do
    let msg = (Message None m)
    case s of
        ServerProcess pid  -> BaseProcess.send  pid  msg 
        NamedServer   name -> BaseProcess.nsend name msg

-- process request handling

handleRequest :: (Serializable m) => RequestHandler s m -> Dispatcher s
handleRequest = handleRequestIf (const True)

handleRequestIf :: (Serializable a) => (a -> Bool) ->
                RequestHandler s a -> Dispatcher s
handleRequestIf cond handler = DispatchIf {
  dispatch = (\state m@(Message _ _) -> do
      (r, s') <- ST.runStateT (handler m) state
      return (s', r)
  ),
  condition = \_ (Message _ req) -> cond req
}

-- process state management

-- | gets the process state
getState :: Process s s
getState = ST.get

-- | sets the process state
putState :: s -> Process s ()
putState = ST.put

-- | modifies the server state
modifyState :: (s -> s) -> Process s ()
modifyState = ST.modify

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | server process
runProc :: Behaviour s -> Process s ()
runProc s = do
    ir <- init s
    tr <- case ir of
            InitOk t -> do
              trace $ "Server ready to receive messages!"
              loop s t
            InitStop r -> return (TerminateReason r)
    terminate s tr

-- | initialize server
init :: Behaviour s -> Process s InitResult
init s = do
    trace $ "Server initializing ... "
    ir <- initHandler s
    return ir

loop :: Behaviour s -> Timeout -> Process s TerminateReason
loop s t = do
    s' <- processReceive (dispatchers s) t
    nextAction s s' 
    where nextAction :: Behaviour s -> ProcessAction ->
                            Process s TerminateReason
          nextAction b ProcessContinue     = loop b t
          nextAction b (ProcessTimeout t') = loop b t'
          nextAction _ (ProcessStop r)     = return (TerminateReason r) 

processReceive :: [Dispatcher s] -> Timeout -> Process s ProcessAction
processReceive ds timeout = do
    s <- getState
    let ms = map (matchMessage s) ds
    -- TODO: should we drain the message queue to avoid selective receive here?
    case timeout of
        Infinity -> do
            (s', r) <- ST.lift $ BaseProcess.receiveWait ms
            putState s'
            return r
        Timeout t -> do
            result <- ST.lift $ BaseProcess.receiveTimeout (intervalToMs t) ms
            case result of
                Just (s', r) -> do
                  putState s'
                  return r
                Nothing -> do
                  return $ ProcessStop "timed out"

terminate :: Behaviour s -> TerminateReason -> Process s ()
terminate s reason = do
    trace $ "Server terminating: " ++ show reason
    (terminateHandler s) reason

-- | Log a trace message using the underlying Process's say
trace :: String -> Process s ()
trace msg = ST.lift . BaseProcess.say $ msg

-- data Upgrade = ???
-- TODO: can we use 'Static (SerializableDict a)' to pass a Behaviour spec to
-- a remote pid? if so then we may handle hot server-code loading quite easily...

