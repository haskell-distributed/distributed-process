{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.GenProcess
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a high(er) level API for building complex 'Process'
-- implementations by abstracting out the management of the process' mailbox,
-- reply/response handling, timeouts, process hiberation, error handling
-- and shutdown/stop procedures. Whilst this API is intended to provide a
-- higher level of abstraction that vanilla Cloud Haskell, it is intended
-- for use primarilly as a building block.
--
-- [API Overview]
--
-- 
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.GenProcess
  ( -- exported data types
    ServerId(..)
  , Recipient(..)
  , TerminateReason(..)
  , InitResult(..)
  , ProcessAction
  , ProcessReply
  , InitHandler
  , TerminateHandler
  , TimeoutHandler
  , UnhandledMessagePolicy(..)
  , ProcessDefinition(..)
    -- interaction with the process
  , start
  , statelessProcess
  , statelessInit
  , call
  , safeCall
  , callAsync
  , callTimeout
  , cast
    -- interaction inside the process
  , reply
  , replyWith
  , continue
  , timeoutAfter
  , hibernate
  , stop
    -- callback creation
  , handleCall
  , handleCallIf
  , handleCast
  , handleCastIf
  , handleInfo
    -- stateless handlers
  , action
  , handleCall_
  , handleCallIf_
  , handleCast_
  , handleCastIf_
  , continue_
  , timeoutAfter_
  , hibernate_
  , stop_
    -- lower level handlers
  , handleDispatch
  ) where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Async (asyncDo)
import Control.Distributed.Process.Platform.Async.AsyncChan

import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable, typeOf)
import Prelude hiding (init)

data ServerId = ServerId ProcessId | ServerName String

data Recipient =
    SendToPid ProcessId
  | SendToService String
  | SendToRemoteService String NodeId
  deriving (Typeable)
$(derive makeBinary ''Recipient)

data Message a =
    CastMessage a
  | CallMessage a Recipient
  deriving (Typeable)
$(derive makeBinary ''Message)

data CallResponse a = CallResponse a
  deriving (Typeable)
$(derive makeBinary ''CallResponse)

-- | Terminate reason
data TerminateReason =
    TerminateNormal
  | TerminateShutdown
  | TerminateOther String
  deriving (Typeable, Eq, Show)
$(derive makeBinary ''TerminateReason)

-- | Initialization
data InitResult s =
    InitOk s Delay
  | forall r. (Serializable r) => InitFail r

data ProcessAction s =
    ProcessContinue  s
  | ProcessTimeout   TimeInterval s
  | ProcessHibernate TimeInterval s
  | ProcessStop      TerminateReason

data ProcessReply s a =
    ProcessReply a (ProcessAction s)
  | NoReply (ProcessAction s)

type InitHandler      a s   = a -> Process (InitResult s)
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

-- | 
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
    Terminate  -- ^ stop immediately, giving @TerminateOther "UNHANDLED_INPUT"@ as the reason
  | DeadLetter ProcessId -- ^ forward the message to the given recipient
  | Drop                 -- ^ dequeue and then drop/ignore the message

-- | Stores the functions that determine runtime behaviour in response to
-- incoming messages and a policy for responding to unhandled messages. 
data ProcessDefinition s = ProcessDefinition {
    dispatchers
    :: [Dispatcher s]     -- ^ functions that handle call/cast messages
  , infoHandlers
    :: [InfoDispatcher s] -- ^ functions that handle non call/cast messages  
  , timeoutHandler
    :: TimeoutHandler s   -- ^ a function that handles timeouts    
  , terminateHandler
    :: TerminateHandler s -- ^ a function that is run just before the process exits
  , unhandledMessagePolicy
    :: UnhandledMessagePolicy -- ^ how to deal with unhandled messages
  }

--------------------------------------------------------------------------------
-- Cloud Haskell Generic Process API                                          --
--------------------------------------------------------------------------------

-- TODO: automatic registration

-- | Starts a gen-process configured with the supplied process definition,
-- using an init handler and its initial arguments. This code will run the
-- 'Process' until completion and return @Right TerminateReason@ *or*,
-- if initialisation fails, return @Left InitResult@ which will be
-- @InitFail why@.
start :: a
      -> InitHandler a s
      -> ProcessDefinition s
      -> Process (Either (InitResult s) TerminateReason)
start args init behave = do
  ir <- init args
  case ir of
    InitOk s d -> initLoop behave s d >>= return . Right
    f@(InitFail _) -> return $ Left f

-- | A basic, stateless process definition, where the unhandled message policy
-- is set to 'Terminate', the default timeout handlers does nothing (i.e., the
-- same as calling @continue ()@ and the terminate handler is a no-op.
statelessProcess :: ProcessDefinition ()
statelessProcess = ProcessDefinition {
    dispatchers            = []
  , infoHandlers           = []
  , timeoutHandler         = \s _ -> continue s
  , terminateHandler       = \_ _ -> return ()
  , unhandledMessagePolicy = Terminate
  }

statelessInit :: Delay -> InitHandler () ()
statelessInit d () = return $ InitOk () d

-- | Make a syncrhonous call - will block until a reply is received.
call :: forall a b . (Serializable a, Serializable b)
                 => ProcessId -> a -> Process b
call sid msg = callAsync sid msg >>= wait >>= unpack
  where unpack :: AsyncResult b -> Process b
        unpack (AsyncDone   r) = return r
        unpack (AsyncFailed r) = die $ "CALL_FAILED;" ++ show r
        unpack ar              = die $ show (typeOf ar)

-- | Safe version of 'call' that returns 'Nothing' if the operation fails. If
-- you need information about *why* a call has failed then you should use
-- 'call' instead.
safeCall :: forall a b . (Serializable a, Serializable b)
                 => ProcessId -> a -> Process (Maybe b)
safeCall s m = callAsync s m >>= wait >>= unpack
  where unpack (AsyncDone r) = return $ Just r
        unpack _             = return Nothing

-- TODO: provide version of call that will throw/exit on failure

callTimeout :: forall a b . (Serializable a, Serializable b)
                 => ProcessId -> a -> TimeInterval -> Process (Maybe b)
callTimeout s m d = callAsync s m >>= waitTimeout d >>= unpack
  where unpack :: (Serializable b) => Maybe (AsyncResult b) -> Process (Maybe b)
        unpack Nothing              = return Nothing
        unpack (Just (AsyncDone r)) = return $ Just r
        unpack (Just other)         = getSelfPid >>= (flip exit) other >> terminate
-- TODO: https://github.com/haskell-distributed/distributed-process/issues/110

-- | Performs a synchronous 'call' to the the given server address, however the
-- call is made /out of band/ and an async handle is returned immediately. This
-- can be passed to functions in the /Async/ API in order to obtain the result.
--
-- see 'Control.Distributed.Process.Platform.Async' 
-- 
callAsync :: forall a b . (Serializable a, Serializable b)
                 => ProcessId -> a -> Process (AsyncChan b)
callAsync sid msg = do
-- TODO: use a unified async API here if possible
-- https://github.com/haskell-distributed/distributed-process-platform/issues/55
  async $ asyncDo $ do
    mRef <- monitor sid
    wpid <- getSelfPid
    sendTo (SendToPid sid) (CallMessage msg (SendToPid wpid))
    r <- receiveWait [
            match (\((CallResponse m) :: CallResponse b) -> return (Right m))
          , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
              (\(ProcessMonitorNotification _ _ reason) -> return (Left reason))
        ]
    -- TODO: better failure API
    case r of
      Right m -> return m
      Left err -> fail $ "call: remote process died: " ++ show err

-- | Sends a /cast/ message to the server identified by 'ServerId'. The server
-- will not send a response. Like Cloud Haskell's 'send' primitive, cast is
-- fully asynchronous and /never fails/ - therefore 'cast'ing to a non-existent
-- (e.g., dead) process will not generate any errors.
cast :: forall a . (Serializable a)
                 => ProcessId -> a -> Process ()
cast sid msg = send sid (CastMessage msg)

-- Constructing Handlers from *ordinary* functions

-- | Instructs the process to send a reply and continue working.
-- > reply reply' state = replyWith reply' (continue state)
reply :: (Serializable r) => r -> s -> Process (ProcessReply s r)
reply r s = continue s >>= replyWith r

-- | Instructs the process to send a reply /and/ evaluate the 'ProcessAction'.
replyWith :: (Serializable m)
          => m
          -> ProcessAction s
          -> Process (ProcessReply s m)
replyWith msg state = return $ ProcessReply msg state

-- | Instructs the process to continue running and receiving messages.
continue :: s -> Process (ProcessAction s)
continue = return . ProcessContinue

-- | Version of 'continue' that can be used in handlers that ignore process state.
-- 
continue_ :: (s -> Process (ProcessAction s))
continue_ = return . ProcessContinue

-- | Instructs the process to wait for incoming messages until 'TimeInterval'
-- is exceeded. If no messages are handled during this period, the /timeout/
-- handler will be called. Note that this alters the process timeout permanently
-- such that the given @TimeInterval@ will remain in use until changed.
timeoutAfter :: TimeInterval -> s -> Process (ProcessAction s)
timeoutAfter d s = return $ ProcessTimeout d s

-- | Version of 'timeoutAfter' that can be used in handlers that ignore process state.
--
-- > action (\(TimeoutPlease duration) -> timeoutAfter_ duration)
--
timeoutAfter_ :: TimeInterval -> (s -> Process (ProcessAction s))
timeoutAfter_ d = return . ProcessTimeout d

-- | Instructs the process to /hibernate/ for the given 'TimeInterval'. Note
-- that no messages will be removed from the mailbox until after hibernation has
-- ceased. This is equivalent to calling @threadDelay@.
--
hibernate :: TimeInterval -> s -> Process (ProcessAction s)
hibernate d s = return $ ProcessHibernate d s

-- | Version of 'hibernate' that can be used in handlers that ignore process state.
--
-- > action (\(HibernatePlease delay) -> hibernate_ delay) 
--
hibernate_ :: TimeInterval -> (s -> Process (ProcessAction s))
hibernate_ d = return . ProcessHibernate d

-- | Instructs the process to cease, giving the supplied reason for termination.
stop :: TerminateReason -> Process (ProcessAction s)
stop r = return $ ProcessStop r

-- | Version of 'stop' that can be used in handlers that ignore process state.
--
-- > action (\ClientError -> stop_ TerminateNormal) 
--
stop_ :: TerminateReason -> (s -> Process (ProcessAction s))
stop_ r _ = stop r

-- wrapping /normal/ functions with matching functionality

-- | Constructs a 'call' handler from a function in the 'Process' monad.
--
-- > handleCall_ = handleCallIf_ (const True)
--
handleCall_ :: (Serializable a, Serializable b)
           => (a -> Process b)
           -> Dispatcher s
handleCall_ = handleCallIf_ (const True)

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. This variant ignores the state argument present in 'handleCall' and
-- 'handleCallIf' and is therefore useful in a stateless server. Messages are
-- only dispatched to the handler if the supplied condition evaluates to @True@
--
handleCallIf_ :: (Serializable a, Serializable b)
              => (a -> Bool)
              -> (a -> Process b)
              -> Dispatcher s
handleCallIf_ cond handler = DispatchIf {
      dispatch = doHandle handler
    , dispatchIf = doCheckCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (a -> Process b)
                 -> s
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h p) >>= mkReply c s
        doHandle _ _ _ = error "illegal input"
        -- TODO: standard 'this cannot happen' error message

        -- handling 'reply-to' in the main process loop is awkward at best,
        -- so we handle it here instead and return the 'action' to the loop
        mkReply :: (Serializable b)
                => Recipient -> s -> b -> Process (ProcessAction s)
        mkReply c s m = sendTo c (CallResponse m) >> continue s

-- | Constructs a 'call' handler from a function in the 'Process' monad.
-- > handleCall = handleCallIf (const True)
--
handleCall :: (Serializable a, Serializable b)
           => (s -> a -> Process (ProcessReply s b))
           -> Dispatcher s
handleCall = handleCallIf (const True)

-- | Constructs a 'call' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessReply s b))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@
--
handleCallIf :: (Serializable a, Serializable b)
           => (a -> Bool)
           -> (s -> a -> Process (ProcessReply s b))
           -> Dispatcher s
handleCallIf cond handler = DispatchIf {
      dispatch = doHandle handler
    , dispatchIf = doCheckCall cond
    }
  where doHandle :: (Serializable a, Serializable b)
                 => (s -> a -> Process (ProcessReply s b))
                 -> s
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s (CallMessage p c) = (h s p) >>= mkReply c
        doHandle _ _ _ = error "illegal input"
        -- TODO: standard 'this cannot happen' error message

        -- handling 'reply-to' in the main process loop is awkward at best,
        -- so we handle it here instead and return the 'action' to the loop
        mkReply :: (Serializable b)
                => Recipient -> ProcessReply s b -> Process (ProcessAction s)
        mkReply _ (NoReply a) = return a
        mkReply c (ProcessReply r' a) = sendTo c (CallResponse r') >> return a

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad.
-- > handleCast = handleCastIf (const True)
--
handleCast :: (Serializable a)
           => (s -> a -> Process (ProcessAction s)) -> Dispatcher s
handleCast = handleCastIf (const True)

-- | Constructs a 'cast' handler from an ordinary function in the 'Process'
-- monad. Given a function @f :: (s -> a -> Process (ProcessAction s))@,
-- the expression @handleCall f@ will yield a 'Dispatcher' for inclusion
-- in a 'Behaviour' specification for the /GenProcess/.
--
handleCastIf :: (Serializable a)
           => (a -> Bool)
           -> (s -> a -> Process (ProcessAction s))
           -> Dispatcher s
handleCastIf cond h = DispatchIf {
      dispatch   = (\s (CastMessage p) -> h s p)
    , dispatchIf = \_ (CastMessage msg) -> cond msg
    }

-- | Version of 'handleCast' that ignores the server state.
--
handleCast_ :: (Serializable a)
           => (a -> (s -> Process (ProcessAction s))) -> Dispatcher s
handleCast_ = handleCastIf_ (const True)

-- | Version of 'handleCastIf' that ignores the server state.
--
handleCastIf_ :: (Serializable a)
           => (a -> Bool)
           -> (a -> (s -> Process (ProcessAction s)))
           -> Dispatcher s
handleCastIf_ cond h = DispatchIf {
      dispatch   = (\s (CastMessage p) -> h p $ s)
    , dispatchIf = \_ (CastMessage msg) -> cond msg
    }

-- | Constructs an /action/ handler. Like 'handleDispatch' this can handle both
-- 'cast' and 'call' messages and you won't know which you're dealing with.
-- This can be useful where certain inputs require a definite action, such as
-- stopping the server, without concern for the state (e.g., when stopping we
-- need only decide to stop, as the terminate handler can deal with state
-- cleanup etc). For example:
--
-- > action (\MyCriticalErrorSignal -> stop_ TerminateNormal)
--
action :: forall s a . (Serializable a)
                 => (a -> (s -> Process (ProcessAction s)))
                 -> Dispatcher s
action h = handleDispatch perform
  where perform :: (s -> a -> Process (ProcessAction s))
        perform s a = let f = h a in f s

-- | Constructs a handler for both /call/ and /cast/ messages.
-- > handleDispatch = handleDispatchIf (const True)
--
handleDispatch :: (Serializable a)
               => (s -> a -> Process (ProcessAction s))
               -> Dispatcher s
handleDispatch = handleDispatchIf (const True)

-- | Constructs a handler for both /call/ and /cast/ messages. Messages are only
-- dispatched to the handler if the supplied condition evaluates to @True@.
--
handleDispatchIf :: (Serializable a)
                 => (a -> Bool)
                 -> (s -> a -> Process (ProcessAction s))
                 -> Dispatcher s
handleDispatchIf cond handler = DispatchIf {
      dispatch = doHandle handler
    , dispatchIf = doCheck cond
    }
  where doHandle :: (Serializable a)
                 => (s -> a -> Process (ProcessAction s))
                 -> s
                 -> Message a
                 -> Process (ProcessAction s)
        doHandle h s msg =
            case msg of
                (CallMessage p _) -> (h s p)
                (CastMessage p)   -> (h s p)

        doCheck :: forall s a. (Serializable a)
                            => (a -> Bool) -> s -> Message a -> Bool
        doCheck c _ (CallMessage m _) = c m
        doCheck c _ (CastMessage m)   = c m

-- wrapping /normal/ functions with InfoDispatcher

-- | Creates a generic input handler (i.e., for recieved messages that are /not/
-- sent using the 'cast' or 'call' APIs) from an ordinary function in the
-- 'Process' monad.
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

doCheckCall :: forall s a. (Serializable a)
                    => (a -> Bool) -> s -> Message a -> Bool
doCheckCall c _ (CallMessage m _) = c m
doCheckCall _ _ _                 = False

-- Process Implementation

applyPolicy :: s
            -> UnhandledMessagePolicy
            -> AbstractMessage
            -> Process (ProcessAction s)
applyPolicy s p m =
  case p of
    Terminate      -> stop $ TerminateOther "UNHANDLED_INPUT"
    DeadLetter pid -> forward m pid >> continue s
    Drop           -> continue s

initLoop :: ProcessDefinition s -> s -> Delay -> Process TerminateReason
initLoop b s w =
  let p   = unhandledMessagePolicy b
      t   = timeoutHandler b
      ms  = map (matchMessage p s) (dispatchers b)
      ms' = ms ++ addInfoAux p s (infoHandlers b)
  in loop ms' t s w
  where
    addInfoAux :: UnhandledMessagePolicy
               -> s
               -> [InfoDispatcher s]
               -> [Match (ProcessAction s)]
    addInfoAux p ps ds = [matchAny (infoHandler p ps ds)]

    infoHandler :: UnhandledMessagePolicy
                -> s
                -> [InfoDispatcher s]
                -> AbstractMessage
                -> Process (ProcessAction s)
    infoHandler pol st [] msg = applyPolicy st pol msg
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

sendTo :: (Serializable m) => Recipient -> m -> Process ()
sendTo (SendToPid p) m             = send p m
sendTo (SendToService s) m         = nsend s m
sendTo (SendToRemoteService s n) m = nsendRemote n s m

