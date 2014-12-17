{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE PatternGuards              #-}

-- | This is the @Process@ implementation of a /managed process/
module Control.Distributed.Process.Platform.ManagedProcess.Internal.GenProcess
  (recvLoop, precvLoop) where

import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM hiding (check)
import Control.Distributed.Process hiding (call, Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.Platform.ManagedProcess.Server
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import Control.Distributed.Process.Platform.Internal.Queue.PriorityQ
  ( PriorityQ
  , enqueue
  , dequeue
  )
import qualified Control.Distributed.Process.Platform.Internal.Queue.PriorityQ as PriorityQ
  ( empty
  )
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  , Shutdown(..)
  )
import qualified Control.Distributed.Process.Platform.Service.SystemLog as Log
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
  ( cancelTimer
  , runAfter
  , TimerRef
  )
import Control.Monad (void)
import Prelude hiding (init)

--------------------------------------------------------------------------------
-- Priority Mailbox Handling                                                  --
--------------------------------------------------------------------------------

type Queue = PriorityQ Int P.Message
type TimeoutSpec = (Delay, Maybe (TimerRef, (STM ())))
data TimeoutAction s = Stop s ExitReason | Go Delay s

precvLoop :: PrioritisedProcessDefinition s -> s -> Delay -> Process ExitReason
precvLoop ppDef pState recvDelay = do
    void $ verify $ processDef ppDef
    tref <- startTimer recvDelay
    recvQueue ppDef pState tref $ PriorityQ.empty
  where
    verify pDef = mapM_ disallowCC $ apiHandlers pDef

    disallowCC (DispatchCC _ _) = die $ ExitOther "IllegalControlChannel"
    disallowCC _                = return ()

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
    nextAction ac d q'
      | ProcessContinue  s'    <- ac = recvQueueAux p (priorities p) s' d  q'
      | ProcessTimeout   t' s' <- ac = recvQueueAux p (priorities p) s' t' q'
      | ProcessHibernate d' s' <- ac = block d' >> recvQueueAux p (priorities p) s' d q'
      | ProcessStop      r     <- ac = (shutdownHandler $ processDef p) s r >> return r
      | ProcessStopping  s' r  <- ac = (shutdownHandler $ processDef p) s' r >> return r
      | otherwise {- compiler foo -} = die "IllegalState"

    recvQueueAux ppDef prioritizers pState delay queue =
      let ex = (trapExit:(exitHandlers $ processDef ppDef))
          eh = map (\d' -> (dispatchExit d') pState) ex
      in (do t' <- startTimer delay
             mq <- drainMessageQueue pState prioritizers queue
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
      let ex = (trapExit:(exitHandlers def))
          h  = timeoutHandler def in do
        -- as a side effect, this check will cancel the timer
        timedOut <- checkTimer pState tSpec h
        case timedOut of
          Stop s' r -> return $ (ProcessStopping s' r, (fst tSpec), queue)
          Go t' s'  -> do
            -- checkTimer could've run our timeoutHandler, which changes "s"
            case (dequeue queue) of
              Nothing -> do
                -- if the internal queue is empty, we fall back to reading the
                -- actual mailbox, however if /that/ times out, then we need
                -- to let the timeout handler kick in again and make a decision
                drainOrTimeout s' t' queue ps' h
              Just (m', q') -> do
                act <- catchesExit (processApply def s' m')
                                   (map (\d' -> (dispatchExit d') s') ex)
                return (act, t', q')

    processApply def pState msg =
      let pol          = unhandledMessagePolicy def
          apiMatchers  = map (dynHandleMessage pol pState) (apiHandlers def)
          infoMatchers = map (dynHandleMessage pol pState) (infoHandlers def)
          shutdown'    = dynHandleMessage pol pState shutdownHandler'
          ms'          = (shutdown':apiMatchers) ++ infoMatchers
      in processApplyAux ms' pol pState msg

    processApplyAux []     p' s' m' = applyPolicy p' s' m'
    processApplyAux (h:hs) p' s' m' = do
      attempt <- h m'
      case attempt of
        Nothing  -> processApplyAux hs p' s' m'
        Just act -> return act

    drainOrTimeout pState delay queue ps' h = do
      let matches = [ matchMessage return ]
          recv    = case delay of
                      Infinity -> receiveWait matches >>= return . Just
                      NoDelay  -> receiveTimeout 0 matches
                      Delay i  -> receiveTimeout (asTimeout i) matches in do
        r <- recv
        case r of
          Nothing -> h pState delay >>= \act -> return $ (act, delay, queue)
          Just m  -> do
            queue' <- enqueueMessage pState ps' m queue
            -- Returning @ProcessContinue@ simply causes the main loop to go
            -- into 'recvQueueAux', which ends up in 'drainMessageQueue'.
            -- In other words, we continue draining the /real/ mailbox.
            return $ (ProcessContinue pState, delay, queue')

drainMessageQueue :: s -> [DispatchPriority s] -> Queue -> Process Queue
drainMessageQueue pState priorities' queue = do
  m <- receiveTimeout 0 [ matchMessage return ]
  case m of
    Nothing -> return queue
    Just m' -> do
      queue' <- enqueueMessage pState priorities' m' queue
      drainMessageQueue pState priorities' queue'

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

recvLoop :: ProcessDefinition s -> s -> Delay -> Process ExitReason
recvLoop pDef pState recvDelay =
  let p             = unhandledMessagePolicy pDef
      handleTimeout = timeoutHandler pDef
      handleStop    = shutdownHandler pDef
      shutdown'     = matchDispatch p pState shutdownHandler'
      matchers      = map (matchDispatch p pState) (apiHandlers pDef)
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

