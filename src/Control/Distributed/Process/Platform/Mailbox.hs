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
{-# LANGUAGE GADTs                #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Mailbox
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- Generic process that acts as an external mailbox and a message buffer,
-- dropping and/or delivering messages on demand.
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Platform.Mailbox where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Closure (remotable, mkClosure, mkStaticClosure)
import Control.Distributed.Process.Serializable hiding (SerializableDict)
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  , Addressable(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess
  ( call
  , safeCall
  , UnhandledMessagePolicy(..)
  , cast
  , handleInfo
  , reply
  , continue
  , input
  , defaultProcess
  , prioritised
  , InitHandler
  , InitResult(..)
  , ProcessAction
  , ProcessReply
  , ProcessDefinition(..)
  , PrioritisedProcessDefinition(..)
  , DispatchPriority
  , CallRef
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
  ( serve
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server
  ( handleCallIf
  , handleCallFrom
  , handleCallFromIf
  , handleCast
  , stop
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
  ( prioritiseCast_
  , prioritiseCall_
  , prioritiseInfo_
  , setPriority
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( modifyState
  , getState
  , Result
  , RestrictedProcess
  , RestrictedAction
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( handleCall
  , handleCast
  , reply
  , continue
  )
import Control.Distributed.Process.Platform.Time
import Control.Exception (SomeException)
import Control.Monad (forM_, void)
import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (^=)
  , (^.)
  )
import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (.>)
  , (^=)
  , (^.)
  )
import Data.Binary
import Data.Foldable (Foldable)
import qualified Data.Foldable as Foldable
import Data.Maybe (fromJust, isJust)
import Data.Sequence
  ( Seq
  , ViewL(EmptyL, (:<))
  , ViewR(EmptyR, (:>))
  , (<|)
  , (|>)
  , (><)
  , filter)
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable, typeOf)

import GHC.Generics

import Prelude hiding (drop)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- external client/configuration API

-- | Opaque handle to a mailbox.
--
data Mailbox = Mailbox { pid :: !ProcessId }
  deriving (Typeable, Generic, Show, Eq)
instance Binary Mailbox where

instance Addressable Mailbox where
  resolve = return . Just . pid

-- | Describes the different types of buffer.
--
data BufferType =
    Queue -- ^ FIFO buffer, limiter drops the eldest message (queue head)
  | Stack -- ^ unordered buffer, limiter drops the newest (top) message
  | Ring  -- ^ FIFO buffer, limiter refuses (i.e., drops) new messages
  deriving (Typeable, Eq)

-- | Represents the maximum number of messages the internal buffer can hold.
--
type Limit = Integer

-- | A @Closure@ used to filter messages in /active/ mode.
--
type Filter = Closure (Message -> Process FilterResult)

-- | Marker message indicating to the owning process that mail has arrived.
--
data NewMail = NewMail !Mailbox
  deriving (Typeable, Generic, Show)
instance Binary NewMail where

-- | Mail delivery.
--
data Delivery = Delivery { box          :: ProcessId
                         , messages     :: [Message]
                         , count        :: Integer
                         , totalDropped :: Integer
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
              }

defaultState :: BufferType -> Limit -> ProcessId -> BufferState
defaultState bufferT limit' pid =
  BufferState { _mode    = Passive
              , _bufferT = bufferT
              , _limit   = limit'
              , _size    = 0
              , _dropped = 0
              , _owner   = pid
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

sizeLimit :: Integer -> Limit
sizeLimit n
  | n < 1     = error "InvalidLimit"
  | otherwise = n

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
startMailbox p b l = spawnLocal (runMailbox p b l) >>= return . Mailbox

-- | Run the mailbox server loop.
--
runMailbox :: ProcessId -> BufferType -> Limit -> Process ()
runMailbox pid buffT maxSz = do
  link pid
  -- TODO: add control channel support to ManagedProcess and use it here...
  MP.serve (pid, buffT, maxSz) mboxInit (processDefinition pid)

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

notify :: Mailbox -> Process ()
notify Mailbox{..} = cast pid $ SetActiveMode Notify

active :: Mailbox -> Filter -> Process ()
active Mailbox{..} = cast pid . SetActiveMode . Active

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

-- allStatic :: Static (ProcessId -> Int -> Process ())
-- allStatic = staticLabel "$all"

-- > rtable :: RemoteTable
-- > rtable = registerStatic "$send" (toDynamic sendInt)
-- >        . registerStatic "$decodeProcessId" (toDynamic (decode :: ByteString -> Int))
-- >        $ initRemoteTable

-- > sendIntClosure :: ProcessId -> Closure (Int -> Process ())
-- > sendIntClosure pid = closure decoder (encode pid)
-- >   where
-- >     decoder :: Static (ByteString -> Int -> Process ())
-- >     decoder = sendIntStatic `staticCompose` decodeProcessIdStatic

resize :: Mailbox -> Integer -> Process ()
resize Mailbox{..} = cast pid . Resize

post :: Serializable a => Mailbox -> a -> Process ()
post Mailbox{..} = send pid . Post . unsafeWrapMessage

statistics :: Mailbox -> Process MailboxStats
statistics mb = call mb StatsReq

--------------------------------------------------------------------------------
-- Mailbox Initialisation/Startup                                             --
--------------------------------------------------------------------------------

mboxInit :: InitHandler (ProcessId, BufferType, Limit) State
mboxInit (pid, buffT, maxSz) = do
  return $ InitOk initState Infinity
  where
    initState = State Seq.empty $ defaultState buffT maxSz pid

--------------------------------------------------------------------------------
-- Process Definition/State & API Handlers                                    --
--------------------------------------------------------------------------------

processDefinition :: ProcessId
                  -> ProcessDefinition State
processDefinition pid =
  defaultProcess {
    apiHandlers = [
       handleCast              handleControlMessages
     , Restricted.handleCall   handleGetStats
     ]
  , infoHandlers = [handleInfo handlePost]
  , unhandledMessagePolicy = DeadLetter pid
  } :: ProcessDefinition State

handleControlMessages :: State
                      -> ControlMessage
                      -> Process (ProcessAction State)
handleControlMessages st cm
  | (SetActiveMode new) <- cm = activateMode st current new
  | (Resize sz')        <- cm = continue $ adjust sz' st
  | otherwise                 = stop $ ExitOther "IllegalState"
  where
    activateMode :: State -> Mode -> Mode -> Process (ProcessAction State)
    activateMode st' old new
      | Passive <- old
      , Notify  <- new    = run st' sendNotification new
      | Passive    <- old
      , (Active _) <- new = run st' sendMail new
      | Notify     <- old
      , (Active _) <- new = run st' sendMail new
      | (Active _) <- old
      , (Active _) <- new = run st' return new
      | (Active _) <- old
      , Notify     <- new = run st' return new
      | otherwise         = stop $ ExitOther "IllegalStateDetected"

    run :: State
        -> (State -> Process State)
        -> Mode
        -> Process (ProcessAction State)
    run s h n = if sz == 0 then (cont s n) else h (updated s n) >>= continue

    current = (st ^. state ^. mode)
    cont st' new' = continue $ updated st' new'
    updated st' new' = (state .> mode ^= new') st'
    sz = (st ^. state ^. size)

handleGetStats :: StatsReq -> RestrictedProcess State (Result MailboxStats)
handleGetStats _ = Restricted.reply . (^. stats) =<< getState

handlePost :: State -> Post -> Process (ProcessAction State)
handlePost st (Post msg) =
  let st' = insert msg st in do
    continue . (state .> mode ^= Passive) =<< forwardIfNecessary st'
  where
    forwardIfNecessary s
      | Notify   <- currentMode = sendNotification s
      | Active _ <- currentMode = sendMail s
      | otherwise               = return s

    currentMode = (st ^. state ^. mode)

--------------------------------------------------------------------------------
-- Accessors, State/Stats Management & Utilities                              --
--------------------------------------------------------------------------------

sendNotification :: State -> Process State
sendNotification st =
  getSelfPid >>= send (st ^. state ^. owner) . NewMail . Mailbox >> return st

type Count = Integer
type Skipped = Integer

sendMail :: State -> Process State
sendMail st = do
    let Active f = st ^. state ^. mode
    unCl <- catch (unClosure f >>= return . Just)
                  (\(_ :: SomeException) -> return Nothing)
    case unCl of
      Nothing -> return st
      Just f' -> do
        (st', cnt, skipped, msgs) <- applyFilter f' st
        us <- getSelfPid
        send ownerPid $ Delivery { box          = us
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
    getStats (State _ (BufferState _ _ lm sz dr op)) = MailboxStats sz dr lm op

$(remotable ['everything, 'matching])

acceptEverything :: Closure (Message -> Process FilterResult)
acceptEverything = $(mkStaticClosure 'everything)

acceptMatching :: Closure (Closure (Message -> Process FilterResult)
                           -> Message -> Process FilterResult)
acceptMatching = $(mkStaticClosure 'matching)

-- filterMatching :: (Serializable a) => a -> Filter
-- filterMatching = $(mkClosure 'matching)

