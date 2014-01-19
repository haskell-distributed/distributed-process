{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE PatternGuards        #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE EmptyDataDecls       #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE ImpredicativeTypes   #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Execution.Mailbox
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- Generic process that acts as an external mailbox and message buffer.
--
-- [Overview]
--
-- For use when rate limiting is not possible (or desired), this module
-- provides a /buffer process/ that receives mail via its 'post' API, buffers
-- the received messages and delivers them when its /owning process/ asks for
-- them. A mailbox has to be started with a maximum buffer size - the so called
-- /limit/ - and will discard messages once its internal storage reaches this
-- user defined threshold.
--
-- The usual behaviour of the /buffer process/ is to accumulate messages in
-- its internal memory. When a client evaluates 'notify', the buffer will
-- send a 'NewMail' message to the (real) mailbox of its owning process as
-- soon as it has any message(s) ready to deliver. If the buffer already
-- contains undelivered mail, the 'NewMail' message will be dispatched
-- immediately.
--
-- When the owning process wishes to receive mail, evaluating 'deliver' (from
-- any process) will cause the buffer to send its owner a 'Delivery' message
-- containing the accumulated messages and additional information about the
-- number of messages it is delivering, the number of messages dropped since
-- the last delivery and a handle for the mailbox (so that processes can have
-- multiple mailboxes if required, and distinguish between them).
--
-- [Overflow Handling]
--
-- A mailbox handles overflow - when the number of messages it is holding
-- reaches the limit - differently depending on the 'BufferType' selected
-- when it starts. The @Queue@ buffer will, once the limit is reached, drop
-- older messages first (i.e., the head of the queue) to make space for
-- newer ones. The @Ring@ buffer works similarly, but blocks new messages
-- so as to preserve existing ones instead. Finally, the @Stack@ buffer will
-- drop the last (i.e., most recently received) message to make room for new
-- mail.
--
-- Mailboxes can be /resized/ by evaluating 'resize' with a new value for the
-- limit. If the new limit is older that the current/previous one, messages
-- are dropped as though the mailbox had previously seen a volume of mail
-- equal to the difference (in size) between the limits. In this situation,
-- the @Queue@ will drop as many older messages as neccessary to come within
-- the limit, whilst the other two buffer types will drop as many newer messages
-- as needed.
--
-- [Ordering Guarantees]
--
-- When messages are delivered to the owner, they arrive as a list of raw
-- @Message@ entries, given in descending age order (i.e., eldest first).
-- Whilst this approximates the FIFO ordering a process' mailbox would usually
-- offer, the @Stack@ buffer will appear to offer no ordering at all, since
-- it always deletes the most recent message(s). The @Queue@ and @Ring@ buffers
-- will maintain a more queue-like (i.e., FIFO) view of received messages,
-- with the obvious constraint the newer or older data might have been deleted.
--
-- [Post API and Relaying]
--
-- For messages to be properly handled by the mailbox, they /must/ be sent
-- via the 'post' API. Messages sent directly to the mailbox (via @send@ or
-- the @Addressable@ type class @sendTo@ function) /will not be handled via
-- the internal buffers/ or subjected to the mailbox limits. Instead, they
-- will simply be relayed (i.e., forwarded) directly to the owner.
--
-- [Acknowledgements]
--
-- This API is based on the work of Erlang programmers Fred Hebert and
-- Geoff Cant, its design closely mirroring that of the the /pobox/ library
-- application.
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Platform.Execution.Mailbox
  (
    -- * Creating, Starting, Configuring and Running a Mailbox
    Mailbox()
  , startMailbox
  , startSupervisedMailbox
  , createMailbox
  , resize
  , statistics
  , monitor
  , Limit
  , BufferType(..)
  , MailboxStats(..)
    -- * Posting Mail
  , post
    -- * Obtaining Mail and Notifications
  , notify
  , deliver
  , active
  , NewMail(..)
  , Delivery(..)
  , FilterResult(..)
  , acceptEverything
  , acceptMatching
    -- * Remote Table
  , __remoteTable
  ) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TChan
  ( TChan
  , newBroadcastTChanIO
  , dupTChan
  , readTChan
  , writeTChan
  )
import Control.Distributed.Process hiding (call, monitor)
import qualified Control.Distributed.Process as P (monitor)
import Control.Distributed.Process.Closure
  ( remotable
  , mkStaticClosure
  )
import Control.Distributed.Process.Serializable hiding (SerializableDict)
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  , Resolvable(..)
  , Routable(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess
  ( call
  , sendControlMessage
  , channelControlPort
  , handleControlChan
  , handleInfo
  , continue
  , defaultProcess
  , UnhandledMessagePolicy(..)
  , InitHandler
  , InitResult(..)
  , ProcessAction
  , ProcessDefinition(..)
  , ControlChannel
  , ControlPort
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
  ( chanServe
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server
  ( stop
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( getState
  , Result
  , RestrictedProcess
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( handleCall
  , reply
  )
import Control.Distributed.Process.Platform.Supervisor (SupervisorPid)
import Control.Distributed.Process.Platform.Time
import Control.Exception (SomeException)
import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (.>)
  , (^=)
  , (^.)
  )
import Data.Binary
import qualified Data.Foldable as Foldable
import Data.Sequence
  ( Seq
  , ViewL(EmptyL, (:<))
  , ViewR(EmptyR, (:>))
  , (<|)
  , (|>)
  )
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)

import GHC.Generics

import Prelude hiding (drop)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- external client/configuration API

-- | Opaque handle to a mailbox.
--
data Mailbox = Mailbox { pid   :: !ProcessId
                       , cchan :: !(ControlPort ControlMessage)
                       } deriving (Typeable, Generic, Eq)
instance Binary Mailbox where
instance Show Mailbox where
  show = ("Mailbox:" ++) . show . pid

instance Resolvable Mailbox where
  resolve = return . Just . pid

instance Routable Mailbox where
  sendTo       = post
  unsafeSendTo = post

sendCtrlMsg :: Mailbox
            -> ControlMessage
            -> Process ()
sendCtrlMsg Mailbox{..} = sendControlMessage cchan

-- | Describes the different types of buffer.
--
data BufferType =
    Queue -- ^ FIFO buffer, limiter drops the eldest message (queue head)
  | Stack -- ^ unordered buffer, limiter drops the newest (top) message
  | Ring  -- ^ FIFO buffer, limiter refuses (i.e., drops) new messages
  deriving (Typeable, Eq, Show)

-- TODO: re-implement this process in terms of a limiter expression, i.e.,
--
-- data Limit s = Accept s | Block s
--
-- limit :: forall s. Closure (Message {- new mail -} -> Process (Limit s))

-- | Represents the maximum number of messages the internal buffer can hold.
--
type Limit = Integer

-- | A @Closure@ used to filter messages in /active/ mode.
--
type Filter = Closure (Message -> Process FilterResult)

-- | Marker message indicating to the owning process that mail has arrived.
--
data NewMail = NewMail !Mailbox !Integer
  deriving (Typeable, Generic, Show)
instance Binary NewMail where

-- | Mail delivery.
--
data Delivery = Delivery { box          :: Mailbox -- ^ handle to the sending mailbox
                         , messages     :: [Message] -- ^ list of raw messages
                         , count        :: Integer -- ^ number of messages delivered
                         , totalDropped :: Integer -- ^ total dropped/skipped messages
                         }
  deriving (Typeable, Generic)
instance Binary Delivery where

-- TODO: keep running totals and send them with the stats...

-- | Bundle of statistics data, available on request via
-- the 'mailboxStats' API call.
--
data MailboxStats =
  MailboxStats { pendingMessages :: Integer
               , droppedMessages :: Integer
               , currentLimit    :: Limit
               , owningProcess   :: ProcessId
               } deriving (Typeable, Generic, Show)
instance Binary MailboxStats where

-- internal APIs

data Post = Post !Message
  deriving (Typeable, Generic)
instance Binary Post where

data StatsReq = StatsReq
  deriving (Typeable, Generic)
instance Binary StatsReq where

data FilterResult = Keep | Skip | Send
  deriving (Typeable, Generic)
instance Binary FilterResult

data Mode =
    Active !Filter -- ^ Send all buffered messages (or wait until one arrives)
  | Notify  -- ^ Send a notification once messages are ready to be received
  | Passive -- ^ Accumulate messages in the buffer, dropping them if necessary
  deriving (Typeable, Generic)
instance Binary Mode where
instance Show Mode where
  show (Active _) = "Active"
  show Notify     = "Notify"
  show Passive    = "Passive"

data ControlMessage =
    Resize !Integer
  | SetActiveMode !Mode
  deriving (Typeable, Generic)
instance Binary ControlMessage where

class Buffered a where
  tag    :: a -> BufferType
  push   :: Message -> a -> a
  pop    :: a -> Maybe (Message, a)
  adjust :: Limit -> a -> a
  drop   :: Integer -> a -> a

data BufferState =
  BufferState { _mode    :: Mode
              , _bufferT :: BufferType
              , _limit   :: Limit
              , _size    :: Integer
              , _dropped :: Integer
              , _owner   :: ProcessId
              , ctrlChan :: ControlPort ControlMessage
              }

defaultState :: BufferType
             -> Limit
             -> ProcessId
             -> ControlPort ControlMessage
             -> BufferState
defaultState bufferT limit' pid cc =
  BufferState { _mode    = Passive
              , _bufferT = bufferT
              , _limit   = limit'
              , _size    = 0
              , _dropped = 0
              , _owner   = pid
              , ctrlChan = cc
              }

data State = State { _buffer :: Seq Message
                   , _state  :: BufferState
                   }

instance Buffered State where
  tag q  = _bufferT $ _state q

  -- see note [buffer enqueue/dequeue semantics]
  push m = (state .> size ^: (+1)) . (buffer ^: (m <|))

  -- see note [buffer enqueue/dequeue semantics]
  pop q = maybe Nothing
                (\(s' :> a) -> Just (a, ( (buffer ^= s')
                                        . (state .> size ^: (1-))
                                        $ q))) $ getR (q ^. buffer)

  adjust sz q = (state .> limit ^= sz) $ maybeDrop
    where
      maybeDrop
        | size' <- (q ^. state ^. size),
          size' > sz = (state .> size ^= sz) $ drop (size' - sz) q
        | otherwise  = q

  -- see note [buffer drop semantics]
  drop n q
    | n > 1     = drop (n - 1) $ drop 1 q
    | isQueue q = dropR q
    | otherwise = dropL q
    where
      dropR q' = maybe q' (\(s' :> _) -> dropOne q' s') $ getR (q' ^. buffer)
      dropL q' = maybe q' (\(_ :< s') -> dropOne q' s') $ getL (q' ^. buffer)
      dropOne q' s = ( (buffer ^= s)
                     . (state .> size ^: (\n' -> n' - 1))
                     . (state .> dropped ^: (+1))
                     $ q' )

{- note [buffer enqueue/dequeue semantics]
If we choose to add a message to the buffer, it is always
added to the left hand side of the sequence. This gives
FIFO (enqueue to tail) semantics for queues, LIFO (push
new head) semantics for stacks when dropping messages - note
that dequeueing will always take the eldest (RHS) message,
regardless of the buffer type - and queue-like semantics for
the ring buffer.

We /always/ take the eldest message each time we dequeue,
in an attempt to maintain something approaching FIFO order
when processing the mailbox, for all data structures. Where
we do not achieve this is dropping messages, since the different
buffer types drop messages either on the right (eldest) or left
(youngest).

-- note [buffer drop semantics]

The "stack buffer", when full, only ever attempts to drop the
youngest (leftmost) message, such that it guarantees no ordering
at all, but that is enforced by the code calling 'drop' rather
than the data structure itself. The ring buffer behaves similarly,
since it rejects new messages altogether, which in practise means
dropping from the LHS.

-}

--------------------------------------------------------------------------------
-- Starting/Running a Mailbox                                                 --
--------------------------------------------------------------------------------

-- | Start a mailbox for the calling process.
--
-- > create = getSelfPid >>= start
--
createMailbox :: BufferType -> Limit -> Process Mailbox
createMailbox buffT maxSz =
  getSelfPid >>= \self -> startMailbox self buffT maxSz

-- | Start a mailbox for the supplied @ProcessId@.
--
-- > start = spawnLocal $ run
--
startMailbox :: ProcessId -> BufferType -> Limit -> Process Mailbox
startMailbox = doStartMailbox Nothing

-- | As 'startMailbox', but suitable for use in supervisor child specs.
--
-- Example:
-- > childSpec = toChildStart $ startSupervisedMailbox pid bufferType mboxLimit
--
startSupervisedMailbox :: ProcessId
                       -> BufferType
                       -> Limit
                       -> SupervisorPid
                       -> Process Mailbox
startSupervisedMailbox p b l s = doStartMailbox (Just s) p b l

doStartMailbox :: Maybe SupervisorPid
               -> ProcessId
               -> BufferType
               -> Limit
               -> Process Mailbox
doStartMailbox mSp p b l = do
  bchan <- liftIO $ newBroadcastTChanIO
  rchan <- liftIO $ atomically $ dupTChan bchan
  spawnLocal (maybeLink mSp >> runMailbox bchan p b l) >>= \pid -> do
    cc <- liftIO $ atomically $ readTChan rchan
    return $ Mailbox pid cc
  where
    maybeLink Nothing   = return ()
    maybeLink (Just p') = link p'

-- | Run the mailbox server loop.
--
runMailbox :: TChan (ControlPort ControlMessage)
           -> ProcessId
           -> BufferType
           -> Limit
           -> Process ()
runMailbox tc pid buffT maxSz = do
  link pid
  tc' <- liftIO $ atomically $ dupTChan tc
  MP.chanServe (pid, buffT, maxSz) (mboxInit tc') (processDefinition pid tc)

--------------------------------------------------------------------------------
-- Mailbox Initialisation/Startup                                             --
--------------------------------------------------------------------------------

mboxInit :: TChan (ControlPort ControlMessage)
         -> InitHandler (ProcessId, BufferType, Limit) State
mboxInit tc (pid, buffT, maxSz) = do
  cc <- liftIO $ atomically $ readTChan tc
  return $ InitOk (State Seq.empty $ defaultState buffT maxSz pid cc) Infinity

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

-- | Monitor a mailbox.
--
monitor :: Mailbox -> Process MonitorRef
monitor = P.monitor . pid

-- | Instructs the mailbox to send a 'NewMail' signal as soon as any mail is
-- available for delivery. Once the signal is sent, it will not be resent, even
-- when further mail arrives, until 'notify' is called again.
--
-- NB: signals are /only/ delivered to the mailbox's owning process.
--
notify :: Mailbox -> Process ()
notify mb = sendCtrlMsg mb $ SetActiveMode Notify

-- | Instructs the mailbox to send a 'Delivery' as soon as any mail is
-- available, or immediately (if the buffer already contains data).
--
-- NB: signals are /only/ delivered to the mailbox's owning process.
--
active :: Mailbox -> Filter -> Process ()
active mb f = sendCtrlMsg mb $ SetActiveMode $ Active f

-- | Alters the mailbox's /limit/ - this might cause messages to be dropped!
--
resize :: Mailbox -> Integer -> Process ()
resize mb sz = sendCtrlMsg mb $ Resize sz

-- | Posts a message to someone's mailbox.
--
post :: Serializable a => Mailbox -> a -> Process ()
post Mailbox{..} m = send pid (Post $ wrapMessage m)

-- | Obtain statistics (from/to anywhere) about a mailbox.
--
statistics :: Mailbox -> Process MailboxStats
statistics mb = call mb StatsReq

--------------------------------------------------------------------------------
-- PRIVATE Filter Implementation(s)                                           --
--------------------------------------------------------------------------------

everything :: Message -> Process FilterResult
everything _ = return Keep

matching :: Closure (Message -> Process FilterResult)
         -> Message
         -> Process FilterResult
matching predicate msg = do
  pred' <- unClosure predicate :: Process (Message -> Process FilterResult)
  res   <- handleMessage msg pred'
  case res of
    Nothing -> return Skip
    Just fr -> return fr

--------------------------------------------------------------------------------
-- Process Definition/State & API Handlers                                    --
--------------------------------------------------------------------------------

processDefinition :: ProcessId
                  -> TChan (ControlPort ControlMessage)
                  -> ControlChannel ControlMessage
                  -> Process (ProcessDefinition State)
processDefinition pid tc cc = do
  liftIO $ atomically $ writeTChan tc $ channelControlPort cc
  return $ defaultProcess { apiHandlers = [
                               handleControlChan     cc handleControlMessages
                             , Restricted.handleCall handleGetStats
                             ]
                          , infoHandlers = [handleInfo handlePost]
                          , unhandledMessagePolicy = DeadLetter pid
                          } :: Process (ProcessDefinition State)

handleControlMessages :: State
                      -> ControlMessage
                      -> Process (ProcessAction State)
handleControlMessages st cm
  | (SetActiveMode new) <- cm = activateMode st new
  | (Resize sz')        <- cm = continue $ adjust sz' st
  | otherwise                 = stop $ ExitOther "IllegalState"
  where
    activateMode :: State -> Mode -> Process (ProcessAction State)
    activateMode st' new
      | sz <- (st ^. state ^. size)
      , sz == 0           = continue $ updated st' new
      | otherwise         = do
          let updated' = updated st' new
          case new of
            Notify     -> sendNotification updated' >> continue updated'
            (Active _) -> sendMail updated' >>= continue
            Passive    -> {- shouldn't happen! -} die $ "IllegalState"

    updated s m = (state .> mode ^= m) s

handleGetStats :: StatsReq -> RestrictedProcess State (Result MailboxStats)
handleGetStats _ = Restricted.reply . (^. stats) =<< getState

handlePost :: State -> Post -> Process (ProcessAction State)
handlePost st (Post msg) = do
  let st' = insert msg st
  continue . (state .> mode ^= Passive) =<< forwardIfNecessary st'
  where
    forwardIfNecessary s
      | Notify   <- currentMode = sendNotification s >> return s
      | Active _ <- currentMode = sendMail s
      | otherwise               = return s

    currentMode = st ^. state ^. mode

--------------------------------------------------------------------------------
-- Accessors, State/Stats Management & Utilities                              --
--------------------------------------------------------------------------------

sendNotification :: State -> Process ()
sendNotification st = do
    pid <- getSelfPid
    send ownerPid $ NewMail (Mailbox pid cchan) pending
  where
    ownerPid = st ^. state ^. owner
    pending  = st ^. state ^. size
    cchan    = ctrlChan (st ^. state)

type Count = Integer
type Skipped = Integer

sendMail :: State -> Process State
sendMail st = do
    let Active f = st ^. state ^. mode
    unCl <- catch (unClosure f >>= return . Just)
                  (\(_ :: SomeException) -> return Nothing)
    case unCl of
      Nothing -> return st -- TODO: Logging!?
      Just f' -> do
        (st', cnt, skipped, msgs) <- applyFilter f' st
        us <- getSelfPid
        send ownerPid $ Delivery { box          = Mailbox us (ctrlChan $ st ^. state)
                                 , messages     = Foldable.toList msgs
                                 , count        = cnt
                                 , totalDropped = skipped + droppedMsgs
                                 }
        return $ ( (state .> dropped ^= 0)
                 . (state .> size ^: ((cnt + skipped) -))
                 $ st' )
  where
    applyFilter f s = filterMessages f (s, 0, 0, Seq.empty)

    filterMessages :: (Message -> Process FilterResult)
                   -> (State, Count, Skipped, Seq Message)
                   -> Process (State, Count, Skipped, Seq Message)
    filterMessages f accIn@(buff, cnt, drp, acc) = do
      case pop buff of
        Nothing         -> return accIn
        Just (m, buff') -> do
          res <- f m
          case res of
            Keep -> filterMessages f (buff', cnt + 1, drp, acc |> m)
            Skip -> filterMessages f (buff', cnt, drp + 1, acc)
            Send -> return accIn

    ownerPid    = st ^. state ^. owner
    droppedMsgs = st ^. state ^. dropped

insert :: Message -> State -> State
insert msg st@(State _ BufferState{..}) =
  if _size /= _limit
     then push msg st
     else case _bufferT of
            Ring -> (state .> dropped ^: (+1)) st
            _    -> push msg $ drop 1 st

isQueue :: State -> Bool
isQueue = (== Queue) . _bufferT . _state

isStack :: State -> Bool
isStack = (== Stack) . _bufferT . _state

getR :: Seq a -> Maybe (ViewR a)
getR s =
  case Seq.viewr s of
    EmptyR -> Nothing
    a      -> Just a

getL :: Seq a -> Maybe (ViewL a)
getL s =
  case Seq.viewl s of
    EmptyL -> Nothing
    a      -> Just a

mode :: Accessor BufferState Mode
mode = accessor _mode (\m st -> st { _mode = m })

bufferType :: Accessor BufferState BufferType
bufferType = accessor _bufferT (\t st -> st { _bufferT = t })

limit :: Accessor BufferState Limit
limit = accessor _limit (\l st -> st { _limit = l })

size :: Accessor BufferState Integer
size = accessor _size (\s st -> st { _size = s })

dropped :: Accessor BufferState Integer
dropped = accessor _dropped (\d st -> st { _dropped = d })

owner :: Accessor BufferState ProcessId
owner = accessor _owner (\o st -> st { _owner = o })

buffer :: Accessor State (Seq Message)
buffer = accessor _buffer (\b qb -> qb { _buffer = b })

state :: Accessor State BufferState
state = accessor _state (\s qb -> qb { _state = s })

stats :: Accessor State MailboxStats
stats = accessor getStats (\_ s -> s) -- TODO: use a READ ONLY accessor for this
  where
    getStats (State _ (BufferState _ _ lm sz dr op _)) = MailboxStats sz dr lm op

$(remotable ['everything, 'matching])

-- | A /do-nothing/ filter that accepts all messages (i.e., returns @Keep@
-- for any input).
acceptEverything :: Closure (Message -> Process FilterResult)
acceptEverything = $(mkStaticClosure 'everything)

-- | A filter that takes a @Closure (Message -> Process FilterResult)@ holding
-- the filter function and applies it remotely (i.e., in the mailbox's own
-- managed process).
--
acceptMatching :: Closure (Closure (Message -> Process FilterResult)
                           -> Message -> Process FilterResult)
acceptMatching = $(mkStaticClosure 'matching)

-- | Instructs the mailbox to deliver all pending messages to the owner.
--
deliver :: Mailbox -> Process ()
deliver mb = active mb acceptEverything

