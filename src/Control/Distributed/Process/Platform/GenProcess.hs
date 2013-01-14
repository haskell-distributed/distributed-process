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

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Time
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
    ProcessContinue  { nextState :: s }
  | ProcessTimeout   { delay :: TimeInterval, nextState :: s }
  | ProcessHibernate { duration :: TimeInterval, nextState :: s }
  | ProcessStop      { reason :: TerminateReason } 

data ProcessReply s a =
    ProcessReply { response :: a
                 , action :: ProcessAction s }
  | NoReply { action :: ProcessAction s}          

type InitHandler      a s   = a -> InitResult s
type TerminateHandler s     = s -> TerminateReason -> Process ()
type TimeoutHandler   s     = s -> Delay -> Process (ProcessAction s)

-- dispatching to implementation callbacks

-- | this type defines dispatch from abstract messages to a typed handler
data Dispatcher s =
    forall a . (Serializable a) => Dispatch {
        dispatch :: s -> Message a -> Process (ProcessAction s)
      }
  | forall a . (Serializable a) => DispatchIf {
        dispatch   :: s -> Message a -> Process (ProcessAction s)
      , dispatchIf :: s -> Message a -> Bool
      }

data InfoDispatcher s = InfoDispatcher {
    dispatchInfo :: s -> AbstractMessage -> Process (Maybe (ProcessAction s))
  }

-- | matches messages of specific types using a dispatcher
class MessageMatcher d where
    matchMessage :: UnhandledMessagePolicy -> s -> d s -> Match (ProcessAction s)

-- | matches messages to a MessageDispatcher
instance MessageMatcher Dispatcher where
  matchMessage _ s (Dispatch        d)      = match (d s)
  matchMessage _ s (DispatchIf      d cond) = matchIf (cond s) (d s)

-- | Policy for handling unexpected messages, i.e., messages which are not
-- sent using the 'call' or 'cast' APIs, and which are not handled by any of the
-- 'handleInfo' handlers.
data UnhandledMessagePolicy =
    Terminate
  | DeadLetter ProcessId
  | Drop

data Behaviour s = Behaviour {
    dispatchers      :: [Dispatcher s]
  , infoHandlers     :: [InfoDispatcher s]
  , timeoutHandler   :: TimeoutHandler s
  , terminateHandler :: TerminateHandler s   -- ^ termination handler
  , unhandledMessagePolicy :: UnhandledMessagePolicy
  }

--------------------------------------------------------------------------------
-- Cloud Haskell Generic Process API                                          --
--------------------------------------------------------------------------------

start :: Process ()
start = undefined

call :: Process ()
call = undefined

cast :: Process ()
cast = undefined

-- Constructing Handlers from *ordinary* functions

-- | INstructs the process to send a reply and continue working. 
-- > reply reply' state = replyWith reply' (continue state)
reply :: (Serializable r) => r -> s -> Process (ProcessReply s r)
reply r s = continue s >>= replyWith r

-- | Instructs the process to send a reply and evaluate the 'ProcessAction'
-- thereafter. 
replyWith :: (Serializable m)
          => m
          -> ProcessAction s
          -> Process (ProcessReply s m)
replyWith msg state = return $ ProcessReply msg state 

-- | Instructs the process to continue running and receiving messages.
continue :: s -> Process (ProcessAction s)
continue s = return $ ProcessContinue s

-- | Instructs the process to wait for incoming messages until 'TimeInterval'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @TimeInterval@ will remain in use until changed.  
timeoutAfter :: TimeInterval -> s -> Process (ProcessAction s)
timeoutAfter d s = return $ ProcessTimeout d s

-- | Instructs the process to /hibernate/ for the given 'TimeInterval'. Note
-- that no messages will be removed from the mailbox until after hibernation has
-- ceased. This is equivalent to calling @threadDelay@.
-- 
hibernate :: TimeInterval -> s -> Process (ProcessAction s)
hibernate d s = return $ ProcessHibernate d s

-- | Instructs the process to cease, giving the supplied reason for termination.
stop :: TerminateReason -> Process (ProcessAction s)
stop r = return $ ProcessStop r

handleCall :: (Serializable a, Serializable b)
           => (s -> a -> Process (ProcessReply s b))
           -> Dispatcher s
handleCall handler = handleCallIf (const True) handler           

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessReply s b))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/.
--
handleCallIf :: (Serializable a, Serializable b)
           => (a -> Bool)
           -> (s -> a -> Process (ProcessReply s b))
           -> Dispatcher s
handleCallIf cond handler = DispatchIf {
      dispatch = doHandle handler
    , dispatchIf = doCheck cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> a -> Process (ProcessReply s b))
                 -> s
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s p) >>= mkReply c
        doHandle _ _ _ = error "illegal input"  
        -- TODO: standard 'this cannot happen' error message
        
        doCheck :: forall s a. (Serializable a)
                            => (a -> Bool) -> s -> Message a -> Bool
        doCheck c _ (CallMessage m _) = c m
        doCheck _ _ _                 = False  
        
        -- handling 'reply-to' in the main process loop is awkward at best,
        -- so we handle it here instead and return the 'action' to the loop
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
           => (s -> a -> Process (ProcessAction s)) -> Dispatcher s
handleCast h = Dispatch { dispatch = (\s (CastMessage p) -> h s p) }

-- | Constructs a 'handleCast' handler, matching on the supplied condition.
--
handleCastIf :: (Serializable a)
           => (a -> Bool)
           -> (s -> a -> Process (ProcessAction s))
           -> Dispatcher s
handleCastIf cond h = DispatchIf {
      dispatch = (\s (CastMessage p) -> h s p)
    , dispatchIf = \_ msg -> cond (payload msg)
    }

handleInfo :: forall s a. (Serializable a)
           => (s -> a -> Process (ProcessAction s))
           -> InfoDispatcher s
handleInfo h = InfoDispatcher { dispatchInfo = doHandleInfo h }
  where 
    doHandleInfo :: forall s2 a2. (Serializable a2)
                             => (s2 -> a2 -> Process (ProcessAction s2))
                             -> s2
                             -> AbstractMessage
                             -> Process (Maybe (ProcessAction s2))
    doHandleInfo h' s msg = maybeHandleMessage msg (h' s)

-- Process Implementation

applyPolicy :: s
            -> UnhandledMessagePolicy
            -> AbstractMessage
            -> Process (ProcessAction s)
applyPolicy s p m =
  case p of
    Terminate      -> stop (TerminateOther "unexpected-input")
    DeadLetter pid -> forward m pid >> continue s
    Drop           -> continue s

initLoop :: Behaviour s -> s -> Process TerminateReason
initLoop b s =
  let p   = unhandledMessagePolicy b
      t   = timeoutHandler b 
      ms  = map (matchMessage p s) (dispatchers b)
      ms' = addInfoHandlers b s p ms
  in loop ms' t s Infinity
  where
    addInfoHandlers :: Behaviour s
                    -> s
                    -> UnhandledMessagePolicy
                    -> [Match (ProcessAction s)]
                    -> [Match (ProcessAction s)] 
    addInfoHandlers b' s' p rms =
        rms ++ addInfoAux p s' (infoHandlers b')
    
    addInfoAux :: UnhandledMessagePolicy
               -> s
               -> [InfoDispatcher s]
               -> [Match (ProcessAction s)]
    addInfoAux _ _  [] = []
    addInfoAux p ps ds = [matchAny (infoHandler p ps ds)] 
        
    infoHandler :: UnhandledMessagePolicy
                -> s
                -> [InfoDispatcher s]
                -> AbstractMessage
                -> Process (ProcessAction s)
    infoHandler _   _  [] _ = error "addInfoAux doest not permit this"
    infoHandler pol st (d:ds :: [InfoDispatcher s]) msg
        | length ds > 0  = let dh = dispatchInfo d in do 
            -- NB: we *do not* want to terminate/dead-letter messages until
            -- we've exhausted all the possible info handlers
            m <- dh st msg
            case m of
              Nothing  -> infoHandler pol st ds msg
              Just act -> return act
          -- but here we *do* let the policy kick in
        | otherwise = let dh = dispatchInfo d in do
            m <- dh st msg
            case m of
              Nothing -> applyPolicy st pol msg
              Just act -> return act 
    
loop :: [Match (ProcessAction s)]
     -> TimeoutHandler s
     -> s
     -> Delay
     -> Process TerminateReason
loop ms h s t = do
    ac <- processReceive ms h s t
    case ac of
      (ProcessContinue s')     -> loop ms h s' t
      (ProcessTimeout t' s')   -> loop ms h s' (Delay t')
      (ProcessHibernate d' s') -> block d' >> loop ms h s' t
      (ProcessStop r)          -> return (r :: TerminateReason)
  where block :: TimeInterval -> Process ()
        block i = liftIO $ threadDelay (asTimeout i)

processReceive :: [Match (ProcessAction s)]
               -> TimeoutHandler s
               -> s
               -> Delay
               -> Process (ProcessAction s)
processReceive ms h s t = do
    next <- recv ms t
    case next of
        Nothing -> h s t
        Just pa -> return pa
  where
    recv :: [Match (ProcessAction s)]
         -> Delay
         -> Process (Maybe (ProcessAction s))
    recv matches d =
        case d of
            Infinity -> receiveWait matches >>= return . Just
            Delay t' -> receiveTimeout (asTimeout t') matches  

-- internal/utility

replyTo :: (Serializable m) => Recipient -> m -> Process ()
replyTo (SendToPid p) m             = send p m
replyTo (SendToService s) m         = nsend s m
replyTo (SendToRemoteService s n) m = nsendRemote n s m

data Reset = Reset 
    deriving (Typeable)
$(derive makeBinary ''Reset) 

type MyState = [String]

demo :: Behaviour MyState
demo = Behaviour {
     dispatchers = [
         handleCall add
       , handleCast reset
       ]
   , infoHandlers = [handleInfo handleMonitorSignal]
   , timeoutHandler = onTimeout
   , terminateHandler = undefined
   , unhandledMessagePolicy = Drop 
   }

add :: MyState -> String -> Process (ProcessReply MyState String)
add s x =
  let s' = (x:s)
  in reply "ok" s'

reset :: MyState -> Reset -> Process (ProcessAction MyState)
reset _ Reset = continue []

handleMonitorSignal :: MyState -> ProcessMonitorNotification -> Process (ProcessAction MyState)
handleMonitorSignal s (ProcessMonitorNotification _ _ _) = continue s

onTimeout :: TimeoutHandler MyState
onTimeout _ _ = stop $ TerminateOther "timeout"
