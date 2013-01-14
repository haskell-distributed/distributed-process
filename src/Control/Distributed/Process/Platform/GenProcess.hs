{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImpredicativeTypes         #-}

module Control.Distributed.Process.Platform.GenProcess where

-- TODO: define API and hide internals...

import Control.Applicative
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Time
import qualified Control.Monad.State as ST
  ( StateT
  , get
  , lift
  , modify
  , put
  , runStateT
  )
import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)
import Prelude hiding (init)

data ServerId = ServerId ProcessId | ServerName String

data Recipient =
    SendToPid ProcessId
  | SendToService String
  | SendToRemoteService String NodeId
  deriving (Typeable)
$(derive makeBinary ''Recipient)

data Message a =
    CastMessage { payload :: a }
  | CallMessage { payload :: a, sender :: Recipient }
  deriving (Typeable)
$(derive makeBinary ''Message)
  
-- | Terminate reason
data TerminateReason =
    TerminateNormal
  | TerminateShutdown
  | forall r. (Serializable r) =>
    TerminateOther r
      deriving (Typeable)

-- | Initialization
data InitResult s =
    InitOk s Delay
  | forall r. (Serializable r) => InitStop r

data ProcessAction s =
    ProcessContinue { nextState :: s }
  | ProcessTimeout  { delay :: Delay, nextState :: s }
  | ProcessHibernate { delay :: Delay, nextState :: s }
  | ProcessStop     { reason :: TerminateReason } 

data ProcessReply s a =
    ProcessReply { response :: a
                 , action :: ProcessAction s }
  | NoReply { action :: ProcessAction s}          

type InitHandler      a s   = a -> InitResult s
type TerminateHandler s     = s -> TerminateReason -> Process ()
type TimeoutHandler   s     = s -> Delay -> Process (ProcessAction s)
type CallHandler      s a b = s -> a -> Process (ProcessReply s b)
type CastHandler      s a   = s -> a -> Process (ProcessAction s)

data Req a b = Req a b 

-- dispatching to implementation callbacks

-- | Dispatcher that knows how to dispatch messages to a handler
-- s The server state
data Dispatcher s =
    forall a . (Serializable a) => Dispatch {
        dispatch :: s -> Message a -> Process (ProcessAction s)
      }
  | forall a . (Serializable a) => DispatchIf {
        dispatch   :: s -> Message a -> Process (ProcessAction s)
      , dispatchIf :: s -> Message a -> Bool
      }
  | forall a . (Serializable a) => DispatchReply {
        handle   :: s -> Message a -> Process (ProcessAction s)
      }
  | forall a . (Serializable a) => DispatchReplyIf {
        handle   :: s -> Message a -> Process (ProcessAction s)
      , handleIf :: s -> Message a -> Bool
      }

-- | Matches messages using a dispatcher
class MessageMatcher d where
    matchMessage :: s -> d s -> Match (ProcessAction s)

-- | Matches messages to a MessageDispatcher
instance MessageMatcher Dispatcher where
  matchMessage s (Dispatch        d)      = match (d s)
  matchMessage s (DispatchIf      d cond) = matchIf (cond s) (d s)
  matchMessage s (DispatchReply   d)      = match (d s)
  matchMessage s (DispatchReplyIf d cond) = matchIf (cond s) (d s)

data Behaviour s = Behaviour {
    dispatchers      :: [Dispatcher s]
  , timeoutHandler   :: TimeoutHandler s
  , terminateHandler :: TerminateHandler s   -- ^ termination handler
  }

-- sending replies

replyTo :: (Serializable m) => Recipient -> m -> Process ()
replyTo (SendToPid p) m = send p m
replyTo (SendToService s) m = nsend s m
replyTo (SendToRemoteService s n) m = nsendRemote n s m

--------------------------------------------------------------------------------
-- Cloud Haskell Generic Process API                                          --
--------------------------------------------------------------------------------

start :: Process ()
start = undefined

stop :: Process ()
stop = undefined 

call :: Process ()
call = undefined

cast :: Process ()
cast = undefined

--------------------------------------------------------------------------------
-- Constructing Handlers from *ordinary* functions                            --
--------------------------------------------------------------------------------

reply :: (Serializable r) => r -> s -> ProcessReply s r
reply r s = replyWith r (ProcessContinue s)

replyWith :: (Serializable m) => m -> ProcessAction s -> ProcessReply s m
replyWith msg state = ProcessReply msg state 

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessReply s b))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/.
--
handleCall :: (Serializable a, Serializable b)
           => (s -> a -> Process (ProcessReply s b)) -> Dispatcher s
handleCall handler = DispatchReplyIf {
      handle = doHandle handler
    , handleIf = doCheck 
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> a -> Process (ProcessReply s b)) -> s
                 -> Message a -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s p) >>= mkReply c
        doHandle _ _ _ = error "illegal input"  
        -- TODO: standard 'this cannot happen' error message
        
        doCheck _ (CallMessage _ _) = True
        doCheck _ _                 = False        
        
        mkReply :: (Serializable b)
                => Recipient -> ProcessReply s b -> Process (ProcessAction s)
        mkReply _ (NoReply a) = return a
        mkReply c (ProcessReply r' a) = replyTo c r' >> return a

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessAction s))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/.
--
handleCast :: (Serializable a)
           => CastHandler s a -> Dispatcher s
handleCast h = Dispatch {
    dispatch = (\s (CastMessage p) -> h s p)
  }            

loop :: Behaviour s -> s -> Delay -> Process TerminateReason
loop b s t = do
    ac <- processReceive s b t
    nextAction b ac
    where nextAction :: Behaviour s -> ProcessAction s -> Process TerminateReason
          nextAction b (ProcessContinue s')   = loop b s' t
          nextAction b (ProcessTimeout t' s') = loop b s' t'
          nextAction _ (ProcessStop r)        = return (r :: TerminateReason)

processReceive :: s -> Behaviour s -> Delay -> Process (ProcessAction s)
processReceive s b t =
    let ms = map (matchMessage s) (dispatchers b) in do
    next <- recv ms t
    case next of
        Nothing -> (timeoutHandler b) s t
        Just pa -> return pa
  where
    recv :: [Match (ProcessAction s)] -> Delay -> Process (Maybe (ProcessAction s))
    recv matches d =
        case d of
            Infinity -> receiveWait matches >>= return . Just
            Delay t' -> receiveTimeout (asTimeout t') matches

demo :: Behaviour [String]
demo =
  Behaviour {
      dispatchers = [
          handleCall add
      ]
    , terminateHandler = undefined
    }

add :: [String] -> String -> Process (ProcessReply [String] String)
add s x =
  let s' = (x:s)
  in return $ reply "ok" s'

onTimeout :: TimeoutHandler [String]
onTimeout _ _ = return ProcessStop { reason = (TerminateOther "timeout") }

