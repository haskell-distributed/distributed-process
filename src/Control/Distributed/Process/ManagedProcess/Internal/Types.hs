{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Types used throughout the ManagedProcess framework
module Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
  ( -- * Exported data types
    InitResult(..)
  , Condition(..)
  , ProcessAction(..)
  , ProcessReply(..)
  , CallHandler
  , CastHandler
  , DeferredCallHandler
  , StatelessCallHandler
  , InfoHandler
  , ChannelHandler
  , StatelessChannelHandler
  , InitHandler
  , ShutdownHandler
  , TimeoutHandler
  , UnhandledMessagePolicy(..)
  , ProcessDefinition(..)
  , Priority(..)
  , DispatchPriority(..)
  , PrioritisedProcessDefinition(..)
  , RecvTimeoutPolicy(..)
  , ControlChannel(..)
  , newControlChan
  , ControlPort(..)
  , channelControlPort
  , Dispatcher(..)
  , DeferredDispatcher(..)
  , ExitSignalDispatcher(..)
  , MessageMatcher(..)
  , DynMessageHandler(..)
  , Message(..)
  , CallResponse(..)
  , CallId
  , CallRef(..)
  , makeRef
  , initCall
  , unsafeInitCall
  , waitResponse
  ) where

import Control.Distributed.Process hiding (Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Internal.Types
  ( Recipient(..)
  , ExitReason(..)
  , Addressable
  , Resolvable(..)
  , Routable(..)
  , NFSerializable
  , resolveOrDie
  )
import Control.Distributed.Process.Platform.Time
import Control.DeepSeq (NFData)
import Data.Binary hiding (decode)
import Data.Typeable (Typeable)

import Prelude hiding (init)

import GHC.Generics

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

type CallId = MonitorRef

newtype CallRef a = CallRef { unCaller :: (Recipient, CallId) }
  deriving (Eq, Show, Typeable, Generic)
instance Serializable a => Binary (CallRef a) where
instance NFData a => NFData (CallRef a) where

makeRef :: forall a . (Serializable a) => Recipient -> CallId -> CallRef a
makeRef r c = CallRef (r, c)

instance Resolvable (CallRef a) where
  resolve (CallRef (r, _)) = resolve r

instance Routable (CallRef a) where
  sendTo  (CallRef (client, tag)) msg = sendTo client (CallResponse msg tag)
  unsafeSendTo (CallRef (c, tag)) msg = unsafeSendTo c (CallResponse msg tag)

data Message a b =
    CastMessage a
  | CallMessage a (CallRef b)
  | ChanMessage a (SendPort b)
  deriving (Typeable, Generic)

instance (Serializable a, Serializable b) => Binary (Message a b) where
instance (NFSerializable a, NFSerializable b) => NFData (Message a b) where
deriving instance (Eq a, Eq b) => Eq (Message a b)
deriving instance (Show a, Show b) => Show (Message a b)

data CallResponse a = CallResponse a CallId
  deriving (Typeable, Generic)

instance Serializable a => Binary (CallResponse a)
instance NFSerializable a => NFData (CallResponse a)
deriving instance Eq a => Eq (CallResponse a)
deriving instance Show a => Show (CallResponse a)

-- | Return type for and 'InitHandler' expression.
data InitResult s =
    InitOk s Delay {-
        ^ a successful initialisation, initial state and timeout -}
  | InitStop String {-
        ^ failed initialisation and the reason, this will result in an error -}
  | InitIgnore {-
        ^ the process has decided not to continue starting - this is not an error -}
  deriving (Typeable)

-- | The action taken by a process after a handler has run and its updated state.
-- See 'continue'
--     'timeoutAfter'
--     'hibernate'
--     'stop'
--     'stopWith'
--
data ProcessAction s =
    ProcessContinue  s              -- ^ continue with (possibly new) state
  | ProcessTimeout   Delay        s -- ^ timeout if no messages are received
  | ProcessHibernate TimeInterval s -- ^ hibernate for /delay/
  | ProcessStop      ExitReason     -- ^ stop the process, giving @ExitReason@
  | ProcessStopping  s ExitReason   -- ^ stop the process with @ExitReason@, with updated state

-- | Returned from handlers for the synchronous 'call' protocol, encapsulates
-- the reply data /and/ the action to take after sending the reply. A handler
-- can return @NoReply@ if they wish to ignore the call.
data ProcessReply r s =
    ProcessReply r (ProcessAction s)
  | NoReply (ProcessAction s)

-- | Wraps a predicate that is used to determine whether or not a handler
-- is valid based on some combination of the current process state, the
-- type and/or value of the input message or both.
data Condition s m =
    Condition (s -> m -> Bool)  -- ^ predicated on the process state /and/ the message
  | State     (s -> Bool)       -- ^ predicated on the process state only
  | Input     (m -> Bool)       -- ^ predicated on the input message only

-- | An expression used to handle a /call/ message.
type CallHandler s a b = s -> a -> Process (ProcessReply b s)

-- | An expression used to handle a /call/ message where the reply is deferred
-- via the 'CallRef'.
type DeferredCallHandler s a b = s -> CallRef b -> a -> Process (ProcessReply b s)

-- | An expression used to handle a /call/ message in a stateless process.
type StatelessCallHandler a b = a -> CallRef b -> Process (ProcessReply b ())

-- | An expression used to handle a /cast/ message.
type CastHandler s a = s -> a -> Process (ProcessAction s)

-- | An expression used to handle an /info/ message.
type InfoHandler s a = s -> a -> Process (ProcessAction s)

-- | An expression used to handle a /channel/ message.
type ChannelHandler s a b = s -> SendPort b -> a -> Process (ProcessAction s)

-- | An expression used to handle a /channel/ message in a stateless process.
type StatelessChannelHandler a b = SendPort b -> a -> Process (ProcessAction ())

-- | An expression used to initialise a process with its state.
type InitHandler a s = a -> Process (InitResult s)

-- | An expression used to handle process termination.
type ShutdownHandler s = s -> ExitReason -> Process ()

-- | An expression used to handle process timeouts.
type TimeoutHandler s = s -> Delay -> Process (ProcessAction s)

-- dispatching to implementation callbacks

-- TODO: Now that we've got matchSTM available, we can have two kinds of CC.
-- The easiest approach would be to add an StmControlChannel newtype, since
-- that can't be Serializable (and will have to rely on PCopy for delivery).
-- Rather than write stmChanServe in terms of creating that channel object
-- ourselves (which is necessary for the TypedChannel based approach we
-- currently offer), I think it should accept the (STM a) "read" action and
-- leave the PCopy based delivery nonsense to the user, since we don't want
-- to /encourage/ that sort of thing outside of this codebase.

{-

data InputChannelDispatcher =
  InputChannelDispatcher { chan :: InputChannel s
                         , dispatch :: s -> Message a b -> Process (ProcessAction s)
                         }

instance MessageMatcher Dispatcher where
  matchDispatch _ _ (DispatchInputChannelDispatcher c d) = matchInputChan (d s)
-}

-- | Provides a means for servers to listen on a separate, typed /control/
-- channel, thereby segregating the channel from their regular
-- (and potentially busy) mailbox.
newtype ControlChannel m =
  ControlChannel {
      unControl :: (SendPort (Message m ()), ReceivePort (Message m ()))
    }

-- | Creates a new 'ControlChannel'.
newControlChan :: (Serializable m) => Process (ControlChannel m)
newControlChan = newChan >>= return . ControlChannel

-- | The writable end of a 'ControlChannel'.
--
newtype ControlPort m =
  ControlPort {
      unPort :: SendPort (Message m ())
    } deriving (Show)
deriving instance (Serializable m) => Binary (ControlPort m)
instance Eq (ControlPort m) where
  a == b = unPort a == unPort b

-- | Obtain an opaque expression for communicating with a 'ControlChannel'.
--
channelControlPort :: (Serializable m)
                   => ControlChannel m
                   -> ControlPort m
channelControlPort cc = ControlPort $ fst $ unControl cc

-- | Provides dispatch from cast and call messages to a typed handler.
data Dispatcher s =
    forall a b . (Serializable a, Serializable b) =>
    Dispatch
    {
      dispatch :: s -> Message a b -> Process (ProcessAction s)
    }
  | forall a b . (Serializable a, Serializable b) =>
    DispatchIf
    {
      dispatch   :: s -> Message a b -> Process (ProcessAction s)
    , dispatchIf :: s -> Message a b -> Bool
    }
  | forall a b . (Serializable a, Serializable b) =>
    DispatchCC  -- control channel dispatch
    {
      channel  :: ReceivePort (Message a b)
    , dispatch :: s -> Message a b -> Process (ProcessAction s)
    }

-- | Provides dispatch for any input, returns 'Nothing' for unhandled messages.
data DeferredDispatcher s =
  DeferredDispatcher
  {
    dispatchInfo :: s
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
  }

-- | Provides dispatch for any exit signal - returns 'Nothing' for unhandled exceptions
data ExitSignalDispatcher s =
  ExitSignalDispatcher
  {
    dispatchExit :: s
                 -> ProcessId
                 -> P.Message
                 -> Process (Maybe (ProcessAction s))
  }

class MessageMatcher d where
  matchDispatch :: UnhandledMessagePolicy -> s -> d s -> Match (ProcessAction s)

instance MessageMatcher Dispatcher where
  matchDispatch _ s (Dispatch   d)      = match (d s)
  matchDispatch _ s (DispatchIf d cond) = matchIf (cond s) (d s)
  matchDispatch _ s (DispatchCC c d)    = matchChan c (d s)

class DynMessageHandler d where
  dynHandleMessage :: UnhandledMessagePolicy
                   -> s
                   -> d s
                   -> P.Message
                   -> Process (Maybe (ProcessAction s))

instance DynMessageHandler Dispatcher where
  dynHandleMessage _ s (Dispatch   d)   msg = handleMessage   msg (d s)
  dynHandleMessage _ s (DispatchIf d c) msg = handleMessageIf msg (c s) (d s)
  dynHandleMessage _ _ (DispatchCC _ _) _   = error "ThisCanNeverHappen"

instance DynMessageHandler DeferredDispatcher where
  dynHandleMessage _ s (DeferredDispatcher d) = d s

newtype Priority a = Priority { getPrio :: Int }

data DispatchPriority s =
    PrioritiseCall
    {
      prioritise :: s -> P.Message -> Process (Maybe (Int, P.Message))
    }
  | PrioritiseCast
    {
      prioritise :: s -> P.Message -> Process (Maybe (Int, P.Message))
    }
  | PrioritiseInfo
    {
      prioritise :: s -> P.Message -> Process (Maybe (Int, P.Message))
    }

-- | For a 'PrioritisedProcessDefinition', this policy determines for how long
-- the /receive loop/ should continue draining the process' mailbox before
-- processing its received mail (in priority order).
--
-- If a prioritised /managed process/ is receiving a lot of messages (into its
-- /real/ mailbox), the server might never get around to actually processing its
-- inputs. This (mandatory) policy provides a guarantee that eventually (i.e.,
-- after a specified number of received messages or time interval), the server
-- will stop removing messages from its mailbox and process those it has already
-- received.
--
data RecvTimeoutPolicy = RecvCounter Int | RecvTimer TimeInterval
  deriving (Typeable)

-- | A @ProcessDefinition@ decorated with @DispatchPriority@ for certain
-- input domains.
data PrioritisedProcessDefinition s =
  PrioritisedProcessDefinition
  {
    processDef  :: ProcessDefinition s
  , priorities  :: [DispatchPriority s]
  , recvTimeout :: RecvTimeoutPolicy
  }

-- | Policy for handling unexpected messages, i.e., messages which are not
-- sent using the 'call' or 'cast' APIs, and which are not handled by any of the
-- 'handleInfo' handlers.
data UnhandledMessagePolicy =
    Terminate  -- ^ stop immediately, giving @ExitOther "UnhandledInput"@ as the reason
  | DeadLetter ProcessId -- ^ forward the message to the given recipient
  | Log                  -- ^ log messages, then behave identically to @Drop@
  | Drop                 -- ^ dequeue and then drop/ignore the message

-- | Stores the functions that determine runtime behaviour in response to
-- incoming messages and a policy for responding to unhandled messages.
data ProcessDefinition s = ProcessDefinition {
    apiHandlers  :: [Dispatcher s]     -- ^ functions that handle call/cast messages
  , infoHandlers :: [DeferredDispatcher s] -- ^ functions that handle non call/cast messages
  , exitHandlers :: [ExitSignalDispatcher s] -- ^ functions that handle exit signals
  , timeoutHandler :: TimeoutHandler s   -- ^ a function that handles timeouts
  , shutdownHandler :: ShutdownHandler s -- ^ a function that is run just before the process exits
  , unhandledMessagePolicy :: UnhandledMessagePolicy -- ^ how to deal with unhandled messages
  }

-- note [rpc calls]
-- One problem with using plain expect/receive primitives to perform a
-- synchronous (round trip) call is that a reply matching the expected type
-- could come from anywhere! The Call.hs module uses a unique integer tag to
-- distinguish between inputs but this is easy to forge, and forces all callers
-- to maintain a tag pool, which is quite onerous.
--
-- Here, we use a private (internal) tag based on a 'MonitorRef', which is
-- guaranteed to be unique per calling process (in the absence of mallicious
-- peers). This is handled throughout the roundtrip, such that the reply will
-- either contain the CallId (i.e., the ame 'MonitorRef' with which we're
-- tracking the server process) or we'll see the server die.
--
-- Of course, the downside to all this is that the monitoring and receiving
-- clutters up your mailbox, and if your mailbox is extremely full, could
-- incur delays in delivery. The callAsync function provides a neat
-- work-around for that, relying on the insulation provided by Async.

-- TODO: Generify this /call/ API and use it in Call.hs to avoid tagging

-- TODO: the code below should be moved elsewhere. Maybe to Client.hs?
initCall :: forall s a b . (Addressable s, Serializable a, Serializable b)
         => s -> a -> Process (CallRef b)
initCall sid msg = do
  pid <- resolveOrDie sid "initCall: unresolveable address "
  mRef <- monitor pid
  self <- getSelfPid
  let cRef = makeRef (Pid self) mRef in do
    sendTo pid (CallMessage msg cRef :: Message a b)
    return cRef

unsafeInitCall :: forall s a b . (Addressable s,
                                  NFSerializable a, NFSerializable b)
         => s -> a -> Process (CallRef b)
unsafeInitCall sid msg = do
  pid <- resolveOrDie sid "unsafeInitCall: unresolveable address "
  mRef <- monitor pid
  self <- getSelfPid
  let cRef = makeRef (Pid self) mRef in do
    unsafeSendTo pid (CallMessage msg cRef  :: Message a b)
    return cRef

waitResponse :: forall b. (Serializable b)
             => Maybe TimeInterval
             -> CallRef b
             -> Process (Maybe (Either ExitReason b))
waitResponse mTimeout cRef =
  let (_, mRef) = unCaller cRef
      matchers  = [ matchIf (\((CallResponse _ ref) :: CallResponse b) -> ref == mRef)
                            (\((CallResponse m _) :: CallResponse b) -> return (Right m))
                  , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                      (\(ProcessMonitorNotification _ _ r) -> return (Left (err r)))
                  ]
      err r     = ExitOther $ show r in
    case mTimeout of
      (Just ti) -> finally (receiveTimeout (asTimeout ti) matchers) (unmonitor mRef)
      Nothing   -> finally (receiveWait matchers >>= return . Just) (unmonitor mRef)

