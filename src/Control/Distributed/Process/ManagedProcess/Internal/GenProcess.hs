{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE DeriveDataTypeable         #-}

-- | This is the @Process@ implementation of a /managed process/
module Control.Distributed.Process.ManagedProcess.Internal.GenProcess
  (recvLoop, precvLoop) where

import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM hiding (check)
import Control.Distributed.Process hiding (call, Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.ManagedProcess.Server
import Control.Distributed.Process.ManagedProcess.Internal.Types
import Control.Distributed.Process.Extras.Internal.Queue.PriorityQ
  ( PriorityQ
  , enqueue
  , dequeue
  )
import qualified Control.Distributed.Process.Extras.Internal.Queue.PriorityQ as PriorityQ
  ( empty
  )
import Control.Distributed.Process.Extras
  ( ExitReason(..)
  , Shutdown(..)
  )
import qualified Control.Distributed.Process.Extras.SystemLog as Log
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Timer
  ( cancelTimer
  , runAfter
  , TimerRef
  )
import Control.Monad (void)
import Data.Typeable (Typeable)
import Prelude hiding (init)

--------------------------------------------------------------------------------
-- Priority Mailbox Handling                                                  --
--------------------------------------------------------------------------------

-- TODO: we need to actually utilise recvTimeout on the prioritised pdef, such
-- that a busy mailbox can't prevent us from operating normally.

type Queue = PriorityQ Int P.Message
type TimeoutSpec = (Delay, Maybe (TimerRef, STM ()))
data TimeoutAction s = Stop s ExitReason | Go Delay s

data CancelTimer = CancelTimer deriving (Eq, Show, Typeable)

-- | Prioritised process loop.
--
-- Evaluating this function will cause the caller to enter a server loop,
-- constantly reading messages from its mailbox (and/or other supplied control
-- planes) and passing these to handler functions in the supplied process
-- definition. Only when it is determined that the server process should
-- terminate - either by the handlers deciding to stop the process, or by an
-- unhandled exit signal or other form of failure condition (e.g. synchronous or
-- asynchronous exceptions).
--
precvLoop :: PrioritisedProcessDefinition s -> s -> Delay -> Process ExitReason
precvLoop ppDef pState recvDelay = do
    tref <- startTimer recvDelay
    recvQueue ppDef pState tref PriorityQ.empty

{- note [flow control]

This "receive loop" is a bit daunting, so we'll walk through it bit by bit.

TL;DR we have a recursive structure of

recvQueue >> processNext >>= nextAction
      >>= recvQueueAux | return
          recvQueueAux -> drainMessageQueue >>= recvQueue

First recvQueue attempts to processNext, catching exits and returning
ProcessStop ExitReason if they arrive. The result of processNext will be
a triple of (ProcessAction state, delay, mailQueue).

processNext checks to see if we've timed out, and if we have does the
corresponding work (calling handlers, checks if we're stopping or continuing, etc.)
If we're still running, it tries to dequeue the next message from the Internal
mailQueue (a priority queue of messages) and if this succeeds, evaluates a
handler and yields the resulting ProcessAction.

If the internal mailQueue is empty, processNext evalutes drainOrTimeout, which
performs a real 'receiveTimeout' and yields the next action (possibly enqueueing
any received <<single>> message into mailQueue beforehand).

When nextAction evaluates recvQueueAux, this uses drainMessageQueue to loop over
the process mailbox (and any external matches, such as matchChan or matchSTM
actions), enqueueing messages into mailQueue until no further mail is available,
at which point it gives back the mailQueue.

To prevent a DOS vector - and quite a likely accidental one at that - we do not
sit draining the mailbox indefinitely, since a continuous stream of messages would
leave us unable to process any inputs and we'd eventually run out of memory.
Instead, the PrioritisedProcessDefinition holds a RecvTimeoutPolicy which can
hold either a max-messages-processed limit or a timeout value. Using whichever
policy is provided, drainMessageQueue will stop attempting to receive new mail
either once the message count limit is exceeded or the timer expires, at which
point we go back to processNext.

A note on timeout handling (see the section, Simulated Receive Timeouts later):
we utilise a combination of the Timer module (from -extras) and STM channels to
handle timeouts in the mailbox draining loops. This means that for every time we
go into the mailbox draining loop, we launch a peer process. The overheads are
actually pretty low, but given the variety of work that we do here to handle
prioritisation, the runtime profile of a process using this loop will differ
/significantly/ from an ordinary recvLoop process.

TODO: We have two timers for two different purposes - one that the handlers can
specify as the [max time we should wait for mail before running a timeout
handler], and another that ensures we don't get stuck draining messages forever.
We should leverage just the one timer for this purpose, when the
RecvTimeoutPolicy specifies one, and save ourselves two timers...

TODO: ALSO! The timeout handling here is broken, because we don't listen for
the server's timeout-spec channel in the drain mailbox implementation, which
means we can arrive in processNext /long after the timeout should've expired/
and then notice we'd hit it, and have to continue out of step...

TODO: see nextAction for details on the two things above.

NB: I THINK we can implement both timers using a single control plane, if we
simply hold a broadcastTChan for writing and the readers dupTChan when they
want to receive notifications. The channel can be polled easily during mailbox
draining and written to safely by multiple writers that have dupTChan'd it

-}

recvQueue :: PrioritisedProcessDefinition s
          -> s
          -> TimeoutSpec
          -> Queue
          -> Process ExitReason
recvQueue p s t q =
  let pDef = processDef p
      ps   = priorities p
  in do (ac, d, q') <- catchExit (processNext pDef ps s t q)
                                 (\_ (r :: ExitReason) ->
                                   return (ProcessStop r, Infinity, q))
        nextAction ac d q'
  where
{-
REMOVED COMMENT FROM ABOVE ESSAY UNTIL IMPLEMENTED PROPERLY

Also note that recvQueueAux will immediately pass control to processNext if the
internal queue is non-empty, such that we favour processing message we've
already received over reading our mailbox until we've emptied our internal
queue, at which point our preference switches over to draining the real mailbox
(and other input vectors) until we time out or hit the read size limit.

-}

    nextAction ac d q'
      -- TODO: if PQ.isEmpty q' == False, should we not continue working on
      -- the mail we've already got?
      -- that would mean evaluating something like
      -- recvQueue ppDef pState (delay, Nothing) queue
      | ProcessContinue  s'    <- ac = recvQueueAux p (priorities p) s' d  q'
      | ProcessTimeout   t' s' <- ac = recvQueueAux p (priorities p) s' t' q'
      | ProcessHibernate d' s' <- ac = block d' >> recvQueueAux p (priorities p) s' d q'
      | ProcessStop      r     <- ac = (shutdownHandler $ processDef p) s r >> return r
      | ProcessStopping  s' r  <- ac = (shutdownHandler $ processDef p) s' r >> return r
      | otherwise {- compiler foo -} = die "IllegalState"

    recvQueueAux ppDef prioritizers pState delay queue =
        let pDef = processDef ppDef
            ex   = trapExit:(exitHandlers $ pDef)
            eh   = map (\d' -> (dispatchExit d') pState) ex
            mx   = recvTimeout ppDef
        in (do t' <- startTimer delay
               mq <- drainMessageQueue mx pDef pState prioritizers queue
               recvQueue ppDef pState t' mq)
           `catchExit`
           (\pid (reason :: ExitReason) -> do
               let pd = processDef ppDef
               let ps = pState
               let pq = queue
               let em = unsafeWrapMessage reason
               (a, d, q') <- findExitHandlerOrStop pd ps pq eh pid em
               nextAction a d q')

    findExitHandlerOrStop :: ProcessDefinition s
                          -> s
                          -> Queue
                          -> [ProcessId -> P.Message -> Process (Maybe (ProcessAction s))]
                          -> ProcessId
                          -> P.Message
                          -> Process (ProcessAction s, Delay, Queue)
    findExitHandlerOrStop _ _ pq [] _ er = do
      mEr <- unwrapMessage er :: Process (Maybe ExitReason)
      case mEr of
        Nothing -> die "InvalidExitHandler"  -- TODO: better error message?
        Just er' -> return (ProcessStop er', Infinity, pq)
    findExitHandlerOrStop pd ps pq (eh:ehs) pid er = do
      mAct <- eh pid er
      case mAct of
        Nothing -> findExitHandlerOrStop pd ps pq ehs pid er
        Just pa -> return (pa, Infinity, pq)

    processNext def ps' pState tSpec queue =
      let ex = trapExit:(exitHandlers def)
          h  = timeoutHandler def in do
        -- as a side effect, this check will cancel the timer
        timedOut <- checkTimer pState tSpec h
        case timedOut of
          Stop s' r -> return (ProcessStopping s' r, (fst tSpec), queue)
          Go t' s'  ->
            -- checkTimer could've run our timeoutHandler, which changes "s"
            case dequeue queue of
              Nothing ->
                -- if the internal queue is empty, we fall back to reading the
                -- actual mailbox, however if /that/ times out, then we need
                -- to let the timeout handler kick in again and make a decision
                drainOrTimeout def s' t' queue ps' h
              Just (m', q') -> do
                act <- catchesExit (processApply def s' m')
                                   (map (\d' -> dispatchExit d' s') ex)
                return (act, t', q')

    processApply def pState msg =
      let pol          = unhandledMessagePolicy def
          apiMatchers  = map (dynHandleMessage pol pState) (apiHandlers def)
          infoMatchers = map (dynHandleMessage pol pState) (infoHandlers def)
          extMatchers  = map (dynHandleMessage pol pState) (externHandlers def)
          shutdown'    = dynHandleMessage pol pState shutdownHandler'
          ms'          = (shutdown':apiMatchers) ++ infoMatchers ++ extMatchers
      in processApplyAux ms' pol pState msg

    processApplyAux []     p' s' m' = applyPolicy p' s' m'
    processApplyAux (h:hs) p' s' m' = do
      attempt <- h m'
      case attempt of
        Nothing  -> processApplyAux hs p' s' m'
        Just act -> return act

    drainOrTimeout pDef pState delay queue ps' h =
      let p'       = unhandledMessagePolicy pDef
          matches = ((matchMessage return):map (matchExtern p' pState) (externHandlers pDef))
          recv    = case delay of
                      Infinity -> fmap Just (receiveWait matches)
                      NoDelay  -> receiveTimeout 0 matches
                      Delay i  -> receiveTimeout (asTimeout i) matches in do
        r <- recv
        case r of
          Nothing -> h pState delay >>= \act -> return (act, delay, queue)
          Just m  -> do
            queue' <- enqueueMessage pState ps' m queue
            -- Returning @ProcessContinue@ simply causes the main loop to go
            -- into 'recvQueueAux', which ends up in 'drainMessageQueue'.
            -- In other words, we continue draining the /real/ mailbox.
            return (ProcessContinue pState, delay, queue')

drainMessageQueue :: RecvTimeoutPolicy
                  -> ProcessDefinition s
                  -> s
                  -> [DispatchPriority s]
                  -> Queue
                  -> Process Queue
drainMessageQueue limit pDef pState priorities' queue = do
    timerAcc <- case limit of
                  RecvTimer   tm  -> setupTimer tm
                  RecvCounter cnt -> return $ Right cnt
    drainMessageQueueAux pDef timerAcc pState priorities' queue

  where

    drainMessageQueueAux pd acc st ps q = do
      (acc', m) <- drainIt st pd acc
      -- say $ "drained " ++ show m
      case m of
        Nothing                 -> return q
        Just (Left CancelTimer) -> return q
        Just (Right m')         -> do
          queue' <- enqueueMessage st ps m' q
          drainMessageQueueAux pd acc' st ps queue'

    drainIt :: s
            -> ProcessDefinition s
            -> Either (STM CancelTimer) Int
            -> Process (Either (STM CancelTimer) Int,
                        Maybe (Either CancelTimer P.Message))
    drainIt _  _  e@(Right 0)  = return (e, Just (Left CancelTimer))
    drainIt s' d' (Right cnt)  =
      fmap (Right (cnt - 1), )
           (receiveTimeout 0 (matchAny (return . Right): mkMatchers s' d'))
    drainIt s' d' a@(Left stm) =
      fmap (a, )
           (receiveTimeout 0 ([ matchSTM stm (return . Left)
                              , matchAny     (return . Right)
                              ]  ++ mkMatchers s' d'))

    mkMatchers :: s
               -> ProcessDefinition s
               -> [Match (Either CancelTimer P.Message)]
    mkMatchers st df =
      map (matchMapExtern (unhandledMessagePolicy df) st toRight)
          (externHandlers df)

    toRight :: P.Message -> Either CancelTimer P.Message
    toRight = Right

    setupTimer intv = do
      chan <- liftIO newTChanIO
      void $ runAfter intv $ liftIO $ atomically $ writeTChan chan CancelTimer
      return $ Left (readTChan chan)

enqueueMessage :: s
               -> [DispatchPriority s]
               -> P.Message
               -> Queue
               -> Process Queue
enqueueMessage _ []     m' q = return $ enqueue (-1 :: Int) m' q
enqueueMessage s (p:ps) m' q = let checkPrio = prioritise p s in do
  checkPrio m' >>= maybeEnqueue s m' q ps
  where
    maybeEnqueue :: s
                 -> P.Message
                 -> Queue
                 -> [DispatchPriority s]
                 -> Maybe (Int, P.Message)
                 -> Process Queue
    maybeEnqueue s' msg q' ps' Nothing       = enqueueMessage s' ps' msg q'
    maybeEnqueue _  _   q' _   (Just (i, m)) = return $ enqueue (i * (-1 :: Int)) m q'

--------------------------------------------------------------------------------
-- Ordinary/Blocking Mailbox Handling                                         --
--------------------------------------------------------------------------------

-- | Managed process loop.
--
-- Evaluating this function will cause the caller to enter a server loop,
-- constantly reading messages from its mailbox (and/or other supplied control
-- planes) and passing these to handler functions in the supplied process
-- definition. Only when it is determined that the server process should
-- terminate - either by the handlers deciding to stop the process, or by an
-- unhandled exit signal or other form of failure condition (e.g. synchronous or
-- asynchronous exceptions).
--
recvLoop :: ProcessDefinition s -> s -> Delay -> Process ExitReason
recvLoop pDef pState recvDelay =
  let p             = unhandledMessagePolicy pDef
      handleTimeout = timeoutHandler pDef
      handleStop    = shutdownHandler pDef
      shutdown'     = matchDispatch p pState shutdownHandler'
      extMatchers   = map (matchDispatch p pState) (externHandlers pDef)
      matchers      = extMatchers ++ (map (matchDispatch p pState) (apiHandlers pDef))
      ex'           = (trapExit:(exitHandlers pDef))
      ms' = (shutdown':matchers) ++ matchAux p pState (infoHandlers pDef)
  in do
    ac <- catchesExit (processReceive ms' handleTimeout pState recvDelay)
                      (map (\d' -> (dispatchExit d') pState) ex')
    case ac of
        (ProcessContinue s')     -> recvLoop pDef s' recvDelay
        (ProcessTimeout t' s')   -> recvLoop pDef s' t'
        (ProcessHibernate d' s') -> block d' >> recvLoop pDef s' recvDelay
        (ProcessStop r) -> handleStop pState r >> return (r :: ExitReason)
        (ProcessStopping s' r)   -> handleStop s' r >> return (r :: ExitReason)
  where
    matchAux :: UnhandledMessagePolicy
             -> s
             -> [DeferredDispatcher s]
             -> [Match (ProcessAction s)]
    matchAux p ps ds = [matchAny (auxHandler (applyPolicy p ps) ps ds)]

    auxHandler :: (P.Message -> Process (ProcessAction s))
               -> s
               -> [DeferredDispatcher s]
               -> P.Message
               -> Process (ProcessAction s)
    auxHandler policy _  [] msg = policy msg
    auxHandler policy st (d:ds :: [DeferredDispatcher s]) msg
      | length ds > 0  = let dh = dispatchInfo d in do
        -- NB: we *do not* want to terminate/dead-letter messages until
        -- we've exhausted all the possible info handlers
        m <- dh st msg
        case m of
          Nothing  -> auxHandler policy st ds msg
          Just act -> return act
        -- but here we *do* let the policy kick in
      | otherwise = let dh = dispatchInfo d in do
        m <- dh st msg
        case m of
          Nothing  -> policy msg
          Just act -> return act

    processReceive :: [Match (ProcessAction s)]
                   -> TimeoutHandler s
                   -> s
                   -> Delay
                   -> Process (ProcessAction s)
    processReceive ms handleTimeout st d = do
      next <- recv ms d
      case next of
        Nothing -> handleTimeout st d
        Just pa -> return pa

    recv :: [Match (ProcessAction s)]
         -> Delay
         -> Process (Maybe (ProcessAction s))
    recv matches d' =
      case d' of
        Infinity -> receiveWait matches >>= return . Just
        NoDelay  -> receiveTimeout 0 matches
        Delay t' -> receiveTimeout (asTimeout t') matches

--------------------------------------------------------------------------------
-- Simulated Receive Timeouts                                                 --
--------------------------------------------------------------------------------

startTimer :: Delay -> Process TimeoutSpec
startTimer d
  | Delay t <- d = do sig <- liftIO $ newEmptyTMVarIO
                      tref <- runAfter t $ liftIO $ atomically $ putTMVar sig ()
                      return (d, Just (tref, (readTMVar sig)))
  | otherwise    = return (d, Nothing)

checkTimer :: s
           -> TimeoutSpec
           -> TimeoutHandler s
           -> Process (TimeoutAction s)
checkTimer pState spec handler = let delay = fst spec in do
  timedOut <- pollTimer spec  -- this will cancel the timer
  case timedOut of
    False -> go spec pState
    True  -> do
      act <- handler pState delay
      case act of
        ProcessTimeout   t' s' -> return $ Go t' s'
        ProcessStop      r     -> return $ Stop pState r
        ProcessStopping  s' r  -> return $ Stop s' r
        ProcessHibernate d' s' -> block d' >> go spec s'
        ProcessContinue  s'    -> go spec s'
  where
    go d s = return $ Go (fst d) s

pollTimer :: TimeoutSpec -> Process Bool
pollTimer (_, Nothing         ) = return False
pollTimer (_, Just (tref, sig)) = do
  cancelTimer tref  -- cancelling a dead/completed timer is a no-op
  gotSignal <- liftIO $ atomically $ pollSTM sig
  return $ maybe False (const True) gotSignal
  where
    pollSTM :: (STM ()) -> STM (Maybe ())
    pollSTM sig' = (Just <$> sig') `orElse` return Nothing

--------------------------------------------------------------------------------
-- Utilities                                                                  --
--------------------------------------------------------------------------------

-- an explicit 'cast' giving 'Shutdown' will stop the server gracefully
shutdownHandler' :: Dispatcher s
shutdownHandler' = handleCast (\_ Shutdown -> stop $ ExitNormal)

-- @(ProcessExitException from ExitShutdown)@ will stop the server gracefully
trapExit :: ExitSignalDispatcher s
trapExit = handleExit (\_ _ (r :: ExitReason) -> stop r)

block :: TimeInterval -> Process ()
block i = liftIO $ threadDelay (asTimeout i)

applyPolicy :: UnhandledMessagePolicy
            -> s
            -> P.Message
            -> Process (ProcessAction s)
applyPolicy p s m =
  case p of
    Terminate      -> stop $ ExitOther "UnhandledInput"
    DeadLetter pid -> forward m pid >> continue s
    Drop           -> continue s
    Log            -> logIt >> continue s
  where
    logIt =
      Log.report Log.info Log.logChannel $ "Unhandled Gen Input Message: " ++ (show m)
