{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE EmptyDataDecls           #-}

module Control.Distributed.Platform.Async
  ( AsyncRef
  , AsyncWorkerId
  , AsyncGathererId
  , SpawnAsync
  , AsyncCancel
  , AsyncData
  , Async()
  , AsyncResult(..)
  , async
  , poll
  , check
  , waitTimeout
  , cancel
  , cancelAsync
  , cancelWait
  ) where

import Control.Concurrent.MVar
import Control.Distributed.Platform
  ( sendAfter
  , cancelTimer
  , TimerRef
  , TimeInterval()
  )
import Control.Distributed.Platform.Internal.Types
  ( CancelWait(..)
  )
import Control.Distributed.Process
import Control.Distributed.Process.Serializable

--------------------------------------------------------------------------------
-- Cloud Haskell Async Process API                                            --
--------------------------------------------------------------------------------

-- | A reference to an asynchronous action
type AsyncRef = ProcessId

-- | A reference to an asynchronous worker
type AsyncWorkerId   = AsyncRef

-- | A reference to an asynchronous "gatherer"
type AsyncGathererId = AsyncRef

-- | A function that takes an 'AsyncGathererId' (to which replies should be
-- sent) and spawns an asynchronous (user defined) action, returning the
-- spawned actions 'AsyncWorkerId' in the @Process@ monad. 
type SpawnAsync = AsyncGathererId -> Process AsyncWorkerId

type AsyncData a = MVar (AsyncResult a)

-- | An asynchronous action spawned by 'async'.
-- Asynchronous operations are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
data Async a = Async AsyncRef AsyncRef (AsyncData a)

-- | Represents the result of an asynchronous action, which can be in several
-- states at any given time.
data AsyncResult a =
    AsyncDone a             -- | a completed action and its result
  | AsyncFailed DiedReason  -- | a failed action and the failure reason
  | AsyncCancelled          -- | a cancelled action
  | AsyncPending            -- | a pending action (that is still running)

-- | An async cancellation takes an 'AsyncRef' and does some cancellation
-- operation in the @Process@ monad.
type AsyncCancel = AsyncRef -> Process ()

-- | An asynchronous action spawned by 'async' or 'withAsync'.
-- Asynchronous actions are executed in a separate @Process@, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- There is currently a contract between async workers and 
async :: (Serializable a) => SpawnAsync -> Process (Async a)
async spawnF = do
    mv  <- liftIO $ newEmptyMVar
    (wpid, gpid) <- spawnWorkers spawnF mv
    return (Async wpid gpid mv)
  where
    spawnWorkers :: (Serializable a) =>
                    SpawnAsync -> AsyncData a -> Process (AsyncRef, AsyncRef)
    spawnWorkers sp ad = do
      root <- getSelfPid
      
      -- listener/response proxy
      gpid <- spawnLocal $ do
        proxy  <- getSelfPid
        worker <- sp proxy
        
        send root worker
        
        monRef <- monitor worker
        finally (pollUntilExit worker monRef ad) (unmonitor monRef)
      
      wpid <- expect
      return (wpid, gpid)
    
    -- blocking receive until we see an input message
    pollUntilExit :: (Serializable a) =>
                     ProcessId -> MonitorRef -> AsyncData a -> Process ()
    pollUntilExit pid ref ad = do
        r <- receiveWait [
            matchIf
                (\(ProcessMonitorNotification ref' pid' _) ->
                    ref' == ref && pid == pid')
                (\(ProcessMonitorNotification _    _ r) -> return (Right r))
          , match (\x -> return (Left x))
          ]
        case r of
            Left  a          -> liftIO $ putMVar ad (AsyncDone a)   
            Right DiedNormal -> pollUntilExit pid ref ad -- note [recursion]
            Right d          -> liftIO $ putMVar ad (AsyncFailed d)
            
-- note [recursion]
-- We recurse /just once/ if we've seen a normal exit from our worker. We're
-- absolutely sure about this, because once we've seen DiedNormal for the
-- monitored process, it's not possible to see another monitor signal for it.
-- Based on this, the only other kinds of message that can arrive are the
-- return value from the worker or a cancellation from the coordinating process.

-- | Check whether an 'Async' has completed yet. The status of the asynchronous
-- action is encoded in the returned 'AsyncResult'. If the action has not
-- completed, the result will be 'AsyncPending', or one of the other
-- constructors otherwise. This function does not block waiting for the result.
-- Use 'wait' or 'waitTimeout' if you need blocking/waiting semantics.
-- See 'Async'.
poll :: (Serializable a) => Async a -> Process (AsyncResult a)
poll (Async _ _ d) = do
  mv <- liftIO $ tryTakeMVar d
  case mv of
    Nothing -> return AsyncPending
    Just v  -> return v

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
-- See 'poll'.
check :: (Serializable a) => Async a -> Process (Maybe (AsyncResult a))
check hAsync = poll hAsync >>= \r -> case r of
    AsyncPending -> return Nothing
    ar           -> return (Just ar)  

-- | Wait for an asynchronous operation to complete or timeout. Returns
-- @Nothing@ if the 'AsyncResult' does not change from @AsyncPending@ within
-- the specified delay, otherwise @Just asyncResult@ is returned. If you want
-- to wait/block on the 'AsyncResult' without the indirection of @Maybe@ then
-- consider using 'waitCheck' or 'waitCheckTimeout' instead. 
waitTimeout :: (Serializable a) =>
               TimeInterval -> Async a -> Process (Maybe (AsyncResult a))
waitTimeout t hAsync = do
  self <- getSelfPid
  ar <- poll hAsync
  case ar of
      AsyncPending -> sendAfter t self CancelWait >>= waitAux hAsync
      _            -> return (Just ar)
  where
    waitAux :: (Serializable a) =>
               Async a -> TimerRef -> Process (Maybe (AsyncResult a))
    waitAux a ref =
        getSelfPid >>= spawnWait a ref >> (do "finished" <- expect; check a)  
    
    spawnWait :: (Serializable a) => 
                 Async a -> TimerRef -> ProcessId -> Process (ProcessId)
    spawnWait a ref pid = spawnLocal $ waitLoop a ref pid
    
    waitLoop :: (Serializable a) =>
         Async a -> TimerRef -> ProcessId -> Process ()
    waitLoop asyncHandle ref wAuxPid = do
        m <- waitOne asyncHandle        -- note [wait loop]
        case m of
            Just _  -> finally (send wAuxPid "finished") (cancelTimer ref)
            Nothing -> waitLoop asyncHandle ref wAuxPid 
    
    waitOne :: (Serializable a) => Async a -> Process (Maybe (AsyncResult a))
    waitOne a = do
        m <- receiveTimeout 0 [
            match (\CancelWait -> return AsyncPending)]
        case m of
            Nothing -> check a      -- if we timed out, check the result again
            Just _  -> return m     -- (Just CancelWait) means we're done here

-- note [wait loop]
-- This logic is a bit spaghetti-like so a little explanation:
-- Firstly, we spawn a /waiter/ process so that timing out is simple.
-- Doing this by creating a loop in the caller's process is just a mess,
-- as should be obvious from the necessary type signature once you try it.
-- Instead, the /waiter/ queries its mailbox continually and defers to 'check'
-- to see if the AsyncResult is ready yet.   

-- | Cancel an asynchronous operation. The cancellation method to be used
-- is passed in @asyncCancel@ and can be synchronous (see 'cancelWait') or
-- asynchronous (see 'cancelAsync'). The latter is truly asynchronous, in the
-- same way that message passing is asynchronous, whilst the former will block
-- until a @ProcessMonitorNotification@ is received for all participants in the
-- @Async@ action.
cancel :: Async a -> AsyncCancel -> Process ()
cancel (Async w g d) asyncCancel = do
    asyncCancel w
    asyncCancel g
    liftIO $ tryPutMVar d AsyncCancelled >> return ()

-- | Given an @AsyncRef@, will kill the associated process. This call returns
-- immediately.
cancelAsync :: AsyncCancel
cancelAsync = (flip kill) "cancelled"

-- | Given an @AsyncRef@, will kill the associated process and block until
-- a @ProcessMonitorNotification@ is received, confirming that the process has
-- indeed died. Passing an @AsyncRef@ for a process that has already died is
-- not an error and will not block, so long as the monitor implementation
-- continues to support this. 
cancelWait :: AsyncCancel
cancelWait pid = do
  ref <- monitor pid
  cancelAsync pid
  receiveWait [
    matchIf (\(ProcessMonitorNotification ref' pid' _) ->
                ref' == ref && pid' == pid)
            (\(ProcessMonitorNotification _ _ r) -> return r) ] >> return ()
  