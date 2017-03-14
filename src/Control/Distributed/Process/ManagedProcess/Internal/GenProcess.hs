{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE Rank2Types                 #-}

-- | This is the @Process@ implementation of a /managed process/
module Control.Distributed.Process.ManagedProcess.Internal.GenProcess
  ( recvLoop
  , precvLoop
  , currentTimeout
  , systemTimeout
  , drainTimeout
  , processState
  , processDefinition
  , processFilters
  , processUnhandledMsgPolicy
  , gets
  , getAndModifyState
  , modifyState
  , setUserTimeout
  , setProcessState
  , GenProcess
  , peek
  , push
  , addUserTimer
  , removeUserTimer
  , act
  , runAfter
  , evalAfter
  ) where

import Control.Applicative (liftA2)
import Control.Distributed.Process
  ( match
  , matchAny
  , matchMessage
  , handleMessage
  , handleMessageIf
  , receiveTimeout
  , receiveWait
  , forward
  , catchesExit
  , catchExit
  , die
  , unsafeWrapMessage
  , Process
  , ProcessId
  , Match
  )
import qualified Control.Distributed.Process as P
  ( liftIO
  )
import Control.Distributed.Process.Internal.Types
  ( Message(..)
  , ProcessExitException(..)
  )
import Control.Distributed.Process.ManagedProcess.Server
  ( handleCast
  , handleExitIf
  , stop
  , continue
  )
import Control.Distributed.Process.ManagedProcess.Timer
  ( Timer(timerDelay)
  , TimerKey
  , TimedOut(..)
  , delayTimer
  , startTimer
  , stopTimer
  , matchTimeout
  , matchKey
  , matchRun
  )
import Control.Distributed.Process.ManagedProcess.Internal.Types hiding (Message)
import qualified Control.Distributed.Process.Extras.Internal.Queue.PriorityQ as Q
  ( empty
  , dequeue
  , enqueue
  , peek
  )
import Control.Distributed.Process.Extras
  ( ExitReason(..)
  , Shutdown(..)
  )
import qualified Control.Distributed.Process.Extras.SystemLog as Log
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad (void)
import Control.Monad.Catch
  ( mask_
  , catch
  , throwM
  , mask
  , SomeException
  )
import qualified Control.Monad.State.Strict as ST
  ( get
  )
import Data.IORef (newIORef, atomicModifyIORef')
import Data.Maybe (fromJust)
import qualified Data.Map.Strict as Map
  ( size
  , insert
  , delete
  , lookup
  , empty
  , foldrWithKey
  )

--------------------------------------------------------------------------------
-- Priority Mailbox Handling                                                  --
--------------------------------------------------------------------------------

type Safe = Bool

-- | Evaluate the given function over the @ProcessState s@ for the caller, and
-- return the result.
gets :: forall s a . (ProcessState s -> a) -> GenProcess s a
gets f = ST.get >>= \(s :: State s) -> liftIO $ do
  atomicModifyIORef' s $ \(s' :: ProcessState s) -> (s', f s' :: a)

-- | Modify our state.
modifyState :: (ProcessState s -> ProcessState s) -> GenProcess s ()
modifyState f =
  ST.get >>= \s -> liftIO $ mask_ $ do
    atomicModifyIORef' s $ \s' -> (f s', ())

-- | Modify our state and return a value (potentially from it).
getAndModifyState :: (ProcessState s -> (ProcessState s, a))
                  -> GenProcess s a
getAndModifyState f =
  ST.get >>= \s -> liftIO $ mask_ $ do
    atomicModifyIORef' s $ \s' -> f s'

-- | Set the current process state.
setProcessState :: s -> GenProcess s ()
setProcessState st' =
  modifyState $ \st@ProcessState{..} -> st { procState = st' }

-- | Set the mailbox draining timer.
setDrainTimeout :: Timer -> GenProcess s ()
setDrainTimeout t = modifyState $ \st@ProcessState{..} -> st { sysTimeout = t }

-- | Set the user timeout applied whilst a prioritised process loop is in
-- a blocking receive.
setUserTimeout :: Delay -> GenProcess s ()
setUserTimeout d =
  modifyState $ \st@ProcessState{..} -> st { usrTimeout = d }

-- | Add a /user timer/, bound to the given datum.
addUserTimer :: Timer -> Message -> GenProcess s TimerKey
addUserTimer t m =
  getAndModifyState $ \st@ProcessState{..} ->
    let sz = Map.size usrTimers
        tk = sz + 1
    in (st { usrTimers = (Map.insert tk (t, m) usrTimers) }, tk)

-- | Remove a /user timer/, for the given key.
removeUserTimer :: TimerKey -> GenProcess s ()
removeUserTimer i =
  modifyState $ \st@ProcessState{..} -> st { usrTimers = (Map.delete i usrTimers) }

-- | Consume the timer with the given @TimerKey@. The timer is removed from the
-- @ProcessState@ and given to the supplied expression, whose evaluation is given
-- back to the caller.
consumeTimer :: forall s a . TimerKey -> (Message -> GenProcess s a) -> GenProcess s a
consumeTimer k f = do
  mt <- gets usrTimers
  let tm = Map.lookup k mt
  let ut = Map.delete k mt
  modifyState $ \st@ProcessState{..} -> st { usrTimers = ut }
  case tm of
    Nothing     -> lift $ die $ "GenProcess.consumeTimer - InvalidTimerKey"
    Just (_, m) -> f m

-- | The @ProcessDefinition@ for the current loop.
processDefinition :: GenProcess s (ProcessDefinition s)
processDefinition = gets procDef

-- | The list of prioritisers for the current loop.
processPriorities :: GenProcess s ([DispatchPriority s])
processPriorities = gets procPrio

-- | The list of filters for the current loop.
processFilters :: GenProcess s ([DispatchFilter s])
processFilters = gets procFilters

-- | Evaluates to the user defined state for the currently executing server loop.
processState :: GenProcess s s
processState = gets procState

-- | Evaluates to the @UnhandledMessagePolicy@ for the current loop.
processUnhandledMsgPolicy :: GenProcess s UnhandledMessagePolicy
processUnhandledMsgPolicy = gets (unhandledMessagePolicy . procDef)

-- | The @Timer@ for the system timeout. See @drainTimeout@.
systemTimeout :: GenProcess s Timer
systemTimeout = gets sysTimeout

-- | The policy for the system timeout. This is used to determine how the loop
-- should limit the time spent draining the /real/ process mailbox into our
-- internal priority queue.
timeoutPolicy :: GenProcess s RecvTimeoutPolicy
timeoutPolicy = gets timeoutSpec

-- | The @Delay@ for the @drainTimeout@.
drainTimeout :: GenProcess s Delay
drainTimeout = gets (timerDelay . sysTimeout)

-- | The current (user supplied) timeout.
currentTimeout :: GenProcess s Delay
currentTimeout = gets usrTimeout

-- | Update and store the internal priority queue.
updateQueue :: (Queue -> Queue) -> GenProcess s ()
updateQueue f =
  modifyState $ \st@ProcessState{..} -> st { internalQ = f internalQ }

-- | Evaluate any matching /info handler/ with the supplied datum after waiting
-- for at least @TimeInterval@. The process state (for the resulting @Action s@)
-- is also given and the process loop will go on as per @Server.continue@.
--
-- Informally, evaluating this expression (such that the @Action@ is given as the
-- result of a handler or filter) will ensure that the supplied message (datum)
-- is availble for processing no sooner than @TimeInterval@.
--
-- Currently, this expression creates an @Action@ that triggers immediate
-- evaluation in the process loop before continuing with the given state. The
-- process loop stores a /user timeout/ for the given time interval, which is
-- trigerred like a wait/drain timeout. This implementation is subject to change.
evalAfter :: forall s m . (Serializable m) => TimeInterval -> m -> s -> Action s
evalAfter d m s = act $ runAfter d m >> setProcessState s

-- | Produce an @Action s@ that, if it is the result of a handler, will cause the
-- server loop to evaluate the supplied expression. This is given in the @GenProcess@
-- monad, which is intended for internal use only.
act :: forall s . GenProcess s () -> Action s
act = return . ProcessActivity
{-# WARNING act "This interface is intended for internal use only" #-}

-- | Starts a timer and adds it as a /user timeout/.
runAfter :: forall s m . (Serializable m) => TimeInterval -> m -> GenProcess s ()
runAfter d m = do
  t <- lift $ startTimer (Delay d)
  void $ addUserTimer t (unsafeWrapMessage m)
{-# WARNING runAfter "This interface is intended for internal use only" #-}

--------------------------------------------------------------------------------
-- Internal Priority Queue                                                    --
--------------------------------------------------------------------------------

-- | Dequeue a message from the internal priority queue.
dequeue :: GenProcess s (Maybe Message)
dequeue = getAndModifyState $ \st -> do
            let pq = internalQ st
            case Q.dequeue pq of
              Nothing      -> (st, Nothing)
              Just (m, q') -> (st { internalQ = q' }, Just m)

-- | Peek at the next available message in the internal priority queue, without
-- removing it.
peek :: GenProcess s (Maybe Message)
peek = getAndModifyState $ \st -> do
         let pq = internalQ st
         (st, Q.peek pq)

-- | Push a message to the head of the internal priority queue.
push :: forall s . Message -> GenProcess s ()
push m = do
  st <- processState
  enqueueMessage st [ PrioritiseInfo {
    prioritise = (\_ m' ->
      return $ Just ((101 :: Int), m')) :: s -> Message -> Process (Maybe (Int, Message)) } ] m

-- | Enqueue a message in the internal priority queue. The given message will be
-- evaluated by all the supplied prioritisers, and if none match it, then it will
-- be assigned the lowest possible priority (i.e. put at the back of the queue).
enqueueMessage :: forall s . s
               -> [DispatchPriority s]
               -> Message
               -> GenProcess s ()
enqueueMessage s [] m' =
  enqueueMessage s [ PrioritiseInfo {
    prioritise = (\_ m ->
      return $ Just ((-1 :: Int), m)) :: s -> Message -> Process (Maybe (Int, Message)) } ] m'
enqueueMessage s (p:ps) m' = let checkPrio = prioritise p s in do
    (lift $ checkPrio m') >>= doEnqueue s ps m'
  where
    doEnqueue :: s
              -> [DispatchPriority s]
              -> Message
              -> Maybe (Int, Message)
              -> GenProcess s ()
    doEnqueue s' ps' msg Nothing       = enqueueMessage s' ps' msg
    doEnqueue _  _   _   (Just (i, m)) = updateQueue (Q.enqueue (i * (-1 :: Int)) m)

--------------------------------------------------------------------------------
-- Process Loop Implementations                                               --
--------------------------------------------------------------------------------

-- | Maps handlers to a dynamic action that can take place outside of a
-- expect/recieve block. This is used by the prioritised process loop.
class DynMessageHandler d where
  dynHandleMessage :: UnhandledMessagePolicy
                   -> s
                   -> d s
                   -> Message
                   -> Process (Maybe (ProcessAction s))

instance DynMessageHandler Dispatcher where
  dynHandleMessage _ s (Dispatch   d)   msg = handleMessage msg (d s)
  dynHandleMessage _ s (DispatchIf d c) msg = handleMessageIf msg (c s) (d s)

instance DynMessageHandler ExternDispatcher where
  dynHandleMessage _ s (DispatchCC  _ d)     msg = handleMessage msg (d s)
  dynHandleMessage _ s (DispatchSTM _ d _ _) msg = handleMessage msg (d s)

instance DynMessageHandler DeferredDispatcher where
  dynHandleMessage _ s (DeferredDispatcher d) = d s

-- | Maps filters to an action that can take place outside of a
-- expect/recieve block.
class DynFilterHandler d where
  dynHandleFilter :: s
                  -> d s
                  -> Message
                  -> Process (Maybe (Filter s))

instance DynFilterHandler DispatchFilter where
  dynHandleFilter s (FilterApi d)   msg = handleMessage msg (d s)
  dynHandleFilter s (FilterAny d)   msg = handleMessage msg (d s)
  dynHandleFilter s (FilterRaw d)   msg = d s msg
  dynHandleFilter s (FilterState d) _   = d s

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
-- ensureIOManagerIsRunning before evaluating this loop...
--
precvLoop :: PrioritisedProcessDefinition s
          -> s
          -> Delay
          -> Process ExitReason
precvLoop ppDef pState recvDelay = do
  st <- P.liftIO $ newIORef $ ProcessState { timeoutSpec = recvTimeout ppDef
                                           , sysTimeout  = delayTimer Infinity
                                           , usrTimeout  = recvDelay
                                           , internalQ   = Q.empty
                                           , procState   = pState
                                           , procDef     = processDef ppDef
                                           , procPrio    = priorities ppDef
                                           , procFilters = filters ppDef
                                           , usrTimers   = Map.empty
                                           }

  mask $ \restore -> do
    res <- catch (fmap Right $ restore $ loop st)
                 (\(e :: SomeException) -> return $ Left e)

    -- res could be (Left ex), so we restore process state & def from our IORef
    ps <- P.liftIO $ atomicModifyIORef' st $ \s' -> (s', s')
    let st' = procState ps
        pd = procDef ps
        sh = shutdownHandler pd
    case res of
      Right (exitReason, _) -> do
        restore $ sh (CleanShutdown st') exitReason
        return exitReason
      Left ex -> do
        -- we'll attempt to run the exit handler with the original state
        restore $ sh (LastKnown st') (ExitOther $ show ex)
        throwM ex
  where
    loop st' = catchExit (runProcess st' recvQueue)
                         (\_ (r :: ExitReason) -> return (r, st'))

recvQueue :: GenProcess s ExitReason
recvQueue = do
  pd <- processDefinition
  let ex = trapExit:(exitHandlers $ pd)
  let exHandlers = map (\d' -> (dispatchExit d')) ex

  catch (drainMailbox >> processNext >>= nextAction)
        (\(e :: ProcessExitException) ->
            handleExit exHandlers e >>= nextAction)
  where

    handleExit :: [(s -> ProcessId -> Message -> Process (Maybe (ProcessAction s)))]
               -> ProcessExitException
               -> GenProcess s (ProcessAction s)
    handleExit []     ex                                 = throwM ex
    handleExit (h:hs) ex@(ProcessExitException pid msg) = do
      r <- processState >>= \s -> lift $ h s pid msg
      case r of
        Nothing -> handleExit hs ex
        Just p  -> return p

    nextAction :: ProcessAction s -> GenProcess s ExitReason
    nextAction ac
      | ProcessActivity  act'    <- ac = act' >> recvQueue
      | ProcessSkip              <- ac = recvQueue
      | ProcessContinue  ps'     <- ac = recvQueueAux ps'
      | ProcessTimeout   d   ps' <- ac = setUserTimeout d >> recvQueueAux ps'
      | ProcessStop      xr      <- ac = return xr
      | ProcessStopping  ps' xr  <- ac = setProcessState ps' >> return xr
      | ProcessHibernate d' s'   <- ac = (lift $ block d') >> recvQueueAux s'
      | otherwise {- compiler foo -}   = return $ ExitOther "IllegalState"

    recvQueueAux st = setProcessState st >> recvQueue

      -- TODO: at some point we should re-implement our state monad in terms of
      -- mkWeakIORef instead of a full IORef. At that point, we can implement hiberation
      -- in the following terms:
      -- 1. the user defines (at some level, perhaps outside of this API) some
      --    means for writing a process' state to a backing store
      --    NB: this could be /persistent/, or a file, or database, etc...
      -- 2. when we enter hibernation, we do the following:
      --    (a) write the process state to the chosen backing store
      --    (b) evaluate yield (telling the RTS we're willing to give up our time slice)
      --    (c) enter a blocking receiveWait with no state on our stack...
      --        [NB] presumably at this point our state will be eligible for GC
      --    (d) when we finally receive a message, reboot the process thus:
      --        (i)   read our state back from the given backing store
      --        (ii)  call a user defined function to rebuild the state if custom
      --              actions need to be taken (e.g. they might've stored something
      --              like an STM TVar and need to request a new one from some
      --              well known service or registry - alt. they might want to
      --              /replay/ actions to rebuild their state as an FSM might)
      --        (iii) re-enter the recv loop and immediately processNext
      --
      -- This will give roughly the same semantics as erlang's hibernate/3, although
      -- the RTS does GC globally rather than per-thread, but that might change in
      -- some future release (who knows!?).
      --
      -- Also, this gives us the ability to migrate process state across remote
      -- boundaries. Not only can a process be moved in this way, if we generalise
      -- the mechanism to move a serialised closure, we can migrate the whole process
      -- and its state as well. The main difference here (with ordinary use of
      -- @Closure@ et al for moving processes around, is that we do not insist
      -- on the process state being serializable, simply that they provide a
      -- function to read+write the state, and a (state -> state) function to be
      -- called during rehydration if custom actions need to be taken.
      --

    processNext :: GenProcess s (ProcessAction s)
    processNext = do
      (up, pf) <- gets $ liftA2 (,) (unhandledMessagePolicy . procDef) procFilters
      case pf of
        [] -> consumeMessage
        _  -> filterMessage  (filterNext False up pf Nothing)

    consumeMessage = applyNext dequeue processApply
    filterMessage = applyNext peek

    filterNext :: Safe
               -> UnhandledMessagePolicy
               -> [DispatchFilter s]
               -> Maybe (Filter s)
               -> Message
               -> GenProcess s (ProcessAction s)
    filterNext isSafe mp' fs mf msg
      | Just (FilterSafe s')   <- mf = filterNext True mp' fs (Just $ FilterOk s') msg
      | Just (FilterSkip s')   <- mf = setProcessState s' >> dequeue >> return ProcessSkip
      | Just (FilterStop s' r) <- mf = return $ ProcessStopping s' r
      | isSafe
      , Just (FilterOk s')     <- mf
      , []                     <- fs = do setProcessState s'
                                          act' <- processApply msg
                                          dequeue >> return act'
      | Just (FilterOk s')     <- mf
      , []                     <- fs = setProcessState s' >> applyNext dequeue processApply
      | Nothing <- mf, []      <- fs = applyNext dequeue processApply
      | Just (FilterOk s')     <- mf
      , (f:fs')                <- fs = do
          setProcessState s'
          act' <- lift $ dynHandleFilter s' f msg
          filterNext isSafe mp' fs' act' msg
      | Just (FilterReject _ s') <- mf = do
          setProcessState s' >> dequeue >>= lift . applyPolicy mp' s' . fromJust
      | Nothing <- mf {- filter didn't apply to the input type -}
      , (f:fs') <- fs = processState >>= \s' -> do
          lift (dynHandleFilter s' f msg) >>= \a -> filterNext isSafe mp' fs' a msg

    applyNext :: (GenProcess s (Maybe Message))
              -> (Message -> GenProcess s (ProcessAction s))
              -> GenProcess s (ProcessAction s)
    applyNext queueOp handler = do
      next <- queueOp
      case next of
        Nothing  -> drainOrTimeout
        Just msg -> handler msg

    processApply msg = do
      (def, pState) <- gets $ liftA2 (,) procDef procState

      let pol          = unhandledMessagePolicy def
          apiMatchers  = map (dynHandleMessage pol pState) (apiHandlers def)
          infoMatchers = map (dynHandleMessage pol pState) (infoHandlers def)
          extMatchers  = map (dynHandleMessage pol pState) (externHandlers def)
          shutdown'    = dynHandleMessage pol pState shutdownHandler'
          ms'          = (shutdown':extMatchers) ++ apiMatchers ++ infoMatchers
      processApplyAux ms' pol pState msg

    processApplyAux []     p' s' m' = lift $ applyPolicy p' s' m'
    processApplyAux (h:hs) p' s' m' = do
     attempt <- lift $ h m'
     case attempt of
       Nothing   -> processApplyAux hs p' s' m'
       Just act' -> return act'

    drainMailbox :: GenProcess s ()
    drainMailbox = do
      -- see note [timer handling whilst draining the process' mailbox]
      ps <- processState
      pd <- processDefinition
      pp <- processPriorities
      ut <- gets usrTimers
      let ts = Map.foldrWithKey (\k (t, _) ms -> ms ++ matchKey k t) [] ut
      let ms = ts ++ (matchAny (return . Right) : (mkMatchers ps pd))
      timerAcc <- timeoutPolicy >>= \spec -> case spec of
                                               RecvTimer      _   -> return Nothing
                                               RecvMaxBacklog cnt -> return $ Just cnt
      -- see note [handling async exceptions during non-blocking reads]
      -- Also note that we only use the system timeout here, dropping into the
      -- user timeout only if we end up in a blocking read on the mailbox.
      --
      mask_ $ do
        tt <- maybeStartTimer
        drainAux ps pp timerAcc (ms ++ matchTimeout tt)
        (lift $ stopTimer tt) >>= setDrainTimeout

    drainAux :: s
             -> [DispatchPriority s]
             -> Limit
             -> [Match (Either TimedOut Message)]
             -> GenProcess s ()
    drainAux ps' pp' maxbq ms = do
      (cnt, m) <- scanMailbox maxbq ms
      case m of
        Nothing               -> return ()
        Just (Right m')       -> do enqueueMessage ps' pp' m'
                                    drainAux ps' pp' cnt ms
        Just (Left TimedOut)  -> return ()
        Just (Left (Yield i)) ->
          -- we saw a user defined timer fire, and will have an associated message...
          -- this is a bit complex, we have to enqueue the message and remove the timer
          -- the latter part of which is handled for us by consumeTimer
          consumeTimer i push >> drainAux ps' pp' cnt ms

    maybeStartTimer :: GenProcess s Timer
    maybeStartTimer = do
      tp <- timeoutPolicy
      t <- case tp of
             RecvTimer d -> (lift $ startTimer $ Delay d)
             _           -> return $ delayTimer Infinity
      setDrainTimeout t
      return t

    scanMailbox :: Limit
                -> [Match (Either TimedOut Message)]
                -> GenProcess s (Limit, Maybe (Either TimedOut Message))
    scanMailbox lim ms
      | Just 0 <- lim = return (lim, Just $ Left TimedOut)
      | Just c <- lim = do {- non-blocking read on our mailbox, any external inputs,
                              plus whatever match specs the TimeoutManager gives -}
                        lift $ fmap (Just (c - 1), ) (receiveTimeout 0 ms)
      | otherwise     = lift $ fmap (lim, ) (receiveTimeout 0 ms)

    -- see note [timer handling whilst draining the process' mailbox]
    drainOrTimeout :: GenProcess s (ProcessAction s)
    drainOrTimeout = do
      pd <- processDefinition
      ps <- processState
      ud <- currentTimeout
      mr <- mkMatchRunners
      let ump     = unhandledMessagePolicy pd
          hto     = timeoutHandler pd
          matches = mr ++ ((matchMessage return):map (matchExtern ump ps) (externHandlers pd))
          recv    = case ud of
                      Infinity -> lift $ fmap Just (receiveWait matches)
                      NoDelay  -> lift $ receiveTimeout 0 matches
                      Delay i  -> lift $ receiveTimeout (asTimeout i) matches

      -- see note [masking async exceptions during recv]
      mask $ \restore -> recv >>= \r ->
        case r of
          Nothing -> restore $ lift $ hto ps ud
          Just m  -> do
            pp <- processPriorities
            enqueueMessage ps pp m
            -- Returning @ProcessSkip@ simply causes us to go back into
            -- listening mode until we hit RecvTimeoutPolicy
            restore $ return ProcessSkip

    mkMatchRunners :: GenProcess s [Match Message]
    mkMatchRunners = do
      ut <- gets usrTimers
      fn <- mkRunner
      let ms = Map.foldrWithKey (\k (t, _) ms' -> ms' ++ matchRun fn k t) [] ut
      return ms

    mkRunner :: GenProcess s (TimerKey -> Process Message)
    mkRunner = do
      st <- ST.get
      let fn = \k -> do (m, _) <- runProcess st (consumeTimer k return)
                        return m
      return fn

    mkMatchers :: s
                -> ProcessDefinition s
                -> [Match (Either TimedOut Message)]
    mkMatchers st df =
      map (matchMapExtern (unhandledMessagePolicy df) st toRight)
          (externHandlers df)

    toRight :: Message -> Either TimedOut Message
    toRight = Right

-- note [handling async exceptions during non-blocking reads]
-- Our golden rule is that if we've dequeued any kind of Message at all
-- from the process mailbox (or input channels), we must not /lose/ it
-- if an asynchronous exception arrives. We therefore mask  when we perform a
-- non-blocking scan on the mailbox, and whilst we enqueue messages.
--
-- If an initial scan of the mailbox yields no data, we fall back to making
-- a blocking read; See note [masking async exceptions during recv].
--
-- Once messages have been safely moved from the mailbox to our priority queue,
-- we restore the masking state whilst running handlers.
--

-- note [timer handling whilst draining the process' mailbox]
-- To prevent a DOS vector - and quite a likely accidental one at that - we do not
-- sit draining the mailbox indefinitely, since continuous reading would thus
-- leave us unable to process any inputs and we'd eventually run out of memory.
-- Instead, the PrioritisedProcessDefinition holds a RecvTimeoutPolicy which can
-- hold either a max-messages-processed limit or a timeout value. Using whichever
-- policy is provided, drainMessageQueue will stop attempting to receive new mail
-- either once the message count limit is exceeded or the timer expires, at which
-- point we go back to processNext.

-- note [masking async exceptions during recv]
-- Reading the process' mailbox is mask'ed anyway, however this only
-- covers dequeue on the underlying CQueue, such that either before
-- the dequeue takes place, or after (during evaluation of the result,
-- or execution of the discovered @Match@ for the message), we can still
-- be terminated by an asynchronous exception. This is wrong, from the
-- perspective of a managed process, since in the case of an exit signal
-- we might handle the exception, at which point we've dequeued and
-- subsequently lost a message.
--
-- Masking recv then, prevents this from happening, and is relatively
-- safe, because we know the following (having written all the handlers
-- explicitly ourselves):
--
-- 1. each handler does nothing more than return the underlying message
-- 2. in the most complex case, we have @Left . unsafeWrapMessage@ or
--    @fmap Right readSTM thing@ inside of @matchSTM@
-- 3. We should not, therefore, introduce any uninterruptible behaviour
-- 4. We cannot, however, be certain that this holds true for decoding
--    (and subsequent calls into Binary and/or Bytestrings), so at best
--    we can mask, but not uninterruptibleMask
--
-- NB: According to /qnikst/, atomicModifyIORef' does not require us to
-- use uninterruptibleMask anyway, so this is fine...
--

--------------------------------------------------------------------------------
-- Ordinary/Blocking Mailbox Handling                                         --
--------------------------------------------------------------------------------

-- TODO: wrap recvLoop in the same exception handling as precvLoop
--       notably, we need to ensure the shutdownHandler runs even in the face
--       of exceptions, and it would be useful/good IMO to pass an IORef for
--       the state, so we can have a decent LastKnown value for it

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
        ProcessSkip               -> recvLoop pDef pState recvDelay -- TODO: handle differently...
        (ProcessContinue s')      -> recvLoop pDef s' recvDelay
        (ProcessTimeout t' s')    -> recvLoop pDef s' t'
        (ProcessHibernate d' s')  -> block d' >> recvLoop pDef s' recvDelay
        (ProcessStop r) -> handleStop (LastKnown pState) r >> return (r :: ExitReason)
        (ProcessStopping s' r)    -> handleStop (LastKnown s') r >> return (r :: ExitReason)
        (ProcessActivity _)       -> die $ "recvLoop.InvalidState - ProcessActivityNotSupported"
  where
    matchAux :: UnhandledMessagePolicy
             -> s
             -> [DeferredDispatcher s]
             -> [Match (ProcessAction s)]
    matchAux p ps ds = [matchAny (auxHandler (applyPolicy p ps) ps ds)]

    auxHandler :: (Message -> Process (ProcessAction s))
               -> s
               -> [DeferredDispatcher s]
               -> Message
               -> Process (ProcessAction s)
    auxHandler policy _  [] msg = policy msg
    auxHandler policy st (d:ds :: [DeferredDispatcher s]) msg
      | length ds > 0  = let dh = dispatchInfo d in do
        -- NB: we *do not* want to terminate/dead-letter messages until
        -- we've exhausted all the possible info handlers
        m <- dh st msg
        case m of
          Nothing   -> auxHandler policy st ds msg
          Just act' -> return act'
        -- but here we *do* let the policy kick in
      | otherwise = let dh = dispatchInfo d in do
        m <- dh st msg
        case m of
          Nothing   -> policy msg
          Just act' -> return act'

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
-- Utilities                                                                  --
--------------------------------------------------------------------------------

-- an explicit 'cast' giving 'Shutdown' will stop the server gracefully
shutdownHandler' :: Dispatcher s
shutdownHandler' = handleCast (\_ Shutdown -> stop $ ExitNormal)

-- @(ProcessExitException from ExitShutdown)@ will stop the server gracefully
trapExit :: ExitSignalDispatcher s
trapExit = handleExitIf (\_ e -> e == ExitShutdown)
                        (\_ _ (r :: ExitReason) -> stop r)

block :: TimeInterval -> Process ()
block i =
  void $ receiveTimeout (asTimeout i) [ match (\(_ :: TimedOut) -> return ()) ]

applyPolicy :: UnhandledMessagePolicy
            -> s
            -> Message
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
