{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE EmptyDataDecls            #-}
{-# LANGUAGE StandaloneDeriving        #-}

module Control.Distributed.Platform.Async
  ( -- types/data
    AsyncRef
  , AsyncWorkerId
  , AsyncGathererId
  , AsyncTask
  , AsyncCancel
  , AsyncData
  , Async(worker)
  , AsyncResult(..)
  -- functions for starting/spawning
  , async
  -- and stopping/killing
  , cancel
  , cancelWait
  -- functions to query an async-result
  , poll
  , check
  , wait
  , waitTimeout
  , waitCheckTimeout
  ) where

import Control.Concurrent.MVar
import Control.Distributed.Platform.Timer
  ( sendAfter
  , cancelTimer
  , intervalToMs
  , TimerRef
  )
import Control.Distributed.Platform.Internal.Types
  ( CancelWait(..)
  , TimeInterval()
  )
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
  ( nullProcessId
  )
import Control.Distributed.Process.Serializable

import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)
import Data.Maybe
  ( fromMaybe
  )

--------------------------------------------------------------------------------
-- Cloud Haskell Async Process API                                            --
--------------------------------------------------------------------------------

-- | A reference to an asynchronous action
type AsyncRef = ProcessId

-- | A reference to an asynchronous worker
type AsyncWorkerId   = AsyncRef

-- | A reference to an asynchronous "gatherer"
type AsyncGathererId = AsyncRef

-- | A task to be performed asynchronously. This can either take the
-- form of an action that runs over some type @a@ in the @Process@ monad,
-- or a tuple that adds the node on which the asynchronous task should be
-- spawned - in the @Process a@ case the task is spawned on the local node
type AsyncTask a = Process a

type AsyncData a = MVar (AsyncResult a)

type InternalChannel a = (SendPort (AsyncResult a), ReceivePort (AsyncResult a))

-- | An asynchronous action spawned by 'async'.
-- Asynchronous operations are run in a separate process, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
data Async a = Async {
    worker    :: AsyncWorkerId
  , insulator :: AsyncGathererId
  , channel   :: (InternalChannel a)
  }

-- | Represents the result of an asynchronous action, which can be in several
-- states at any given time.
data AsyncResult a =
    AsyncDone a             -- | a completed action and its result
  | AsyncFailed DiedReason  -- | a failed action and the failure reason
  | AsyncCancelled          -- | a cancelled action
  | AsyncPending            -- | a pending action (that is still running)
    deriving (Typeable)
$(derive makeBinary ''AsyncResult)

deriving instance Eq a => Eq (AsyncResult a)

deriving instance Show a => Show (AsyncResult a)

--instance (Eq a) => Eq (AsyncResult a) where
--  (AsyncDone   x) == (AsyncDone   x') = x == x'
--  (AsyncFailed r) == (AsyncFailed r') = r == r'
--  AsyncCancelled  == AsyncCancelled   = True
--  AsyncPending    == AsyncPending     = True
--  _               == _                = False

-- | An async cancellation takes an 'AsyncRef' and does some cancellation
-- operation in the @Process@ monad.
type AsyncCancel = AsyncRef -> Process ()

-- | An asynchronous action spawned by 'async' or 'withAsync'.
-- Asynchronous actions are executed in a separate @Process@, and
-- operations are provided for waiting for asynchronous actions to
-- complete and obtaining their results (see e.g. 'wait').
--
-- There is currently a contract between async workers and their coordinating
-- processes (including the caller to functions such as 'wait'). Given the
-- process identifier of a gatherer, a worker that wishes to publish some
-- results should send these to the gatherer process when it is finished.
-- Workers that do not return anything should simply exit normally (i.e., they
-- should not call @exit selfPid reason@ not @terminate@ in the base Cloud
-- Haskell APIs) and providing the type of the 'Async' action is @Async ()@
-- then the 'AsyncResult' will be @AsyncDone ()@ instead of the usual
-- @AsyncFailed DiedNormal@ which would normally result from this scenario.
--
async :: (Serializable a) => AsyncTask a -> Process (Async a)
async t = do
    (wpid, gpid, chan) <- spawnWorkers t
    return Async {
        worker    = wpid
      , insulator = gpid
      , channel   = chan
      }

spawnWorkers :: (Serializable a) =>
                AsyncTask a ->
                Process (AsyncRef, AsyncRef, (InternalChannel a))
spawnWorkers task = do
    root <- getSelfPid
    chan <- newChan
  
    -- listener/response proxy
    insulatorPid <- spawnLocal $ do
        workerPid <- spawnLocal $ do
            r <- task
            sendChan (fst chan) (AsyncDone r)
    
        send root workerPid   -- let the parent process know the worker pid
    
        monRef <- monitor workerPid
        finally (pollUntilExit workerPid monRef chan) (unmonitor monRef)
  
    workerPid <- expect
    return (workerPid, insulatorPid, chan)
  where  
    -- blocking receive until we see an input message
    pollUntilExit :: (Serializable a) =>
                     ProcessId -> MonitorRef -> InternalChannel a -> Process ()
    pollUntilExit pid ref (replyTo, _) = do
        r <- receiveWait [
            matchIf
                (\(ProcessMonitorNotification ref' pid' _) ->
                    ref' == ref && pid == pid')
                (\(ProcessMonitorNotification _    _ r) -> return (Right r))
          , match (\c@(CancelWait) -> kill pid "cancel" >> return (Left c))
          ]
        case r of
            Left  CancelWait -> sendChan replyTo AsyncCancelled   
            Right DiedNormal -> return ()
            Right d          -> sendChan replyTo (AsyncFailed d)
            
-- | Check whether an 'Async' has completed yet. The status of the asynchronous
-- action is encoded in the returned 'AsyncResult'. If the action has not
-- completed, the result will be 'AsyncPending', or one of the other
-- constructors otherwise. This function does not block waiting for the result.
-- Use 'wait' or 'waitTimeout' if you need blocking/waiting semantics.
-- See 'Async'.
poll :: (Serializable a) => Async a -> Process (AsyncResult a)
poll hAsync = do
  r <- receiveChanTimeout 0 $ snd (channel hAsync)
  return $ fromMaybe (AsyncPending) r

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
-- See 'poll'.
check :: (Serializable a) => Async a -> Process (Maybe (AsyncResult a))
check hAsync = poll hAsync >>= \r -> case r of
  AsyncPending -> return Nothing
  ar           -> return (Just ar)  

-- | Wait for an asynchronous operation to complete or timeout. This variant
-- returns the 'AsyncResult' itself, which will be 'AsyncPending' if the
-- result has not been made available, otherwise one of the other constructors.
waitCheckTimeout :: (Serializable a) =>
                    TimeInterval -> Async a -> Process (AsyncResult a)
waitCheckTimeout t hAsync =
  waitTimeout t hAsync >>= return . fromMaybe (AsyncPending)

-- | Wait for an asynchronous action to complete, and return its
-- value. The outcome of the action is encoded as an 'AsyncResult'.
--
wait :: (Serializable a) => Async a -> Process (AsyncResult a)
wait hAsync = receiveChan $ snd (channel hAsync)

-- | Wait for an asynchronous operation to complete or timeout. Returns
-- @Nothing@ if the 'AsyncResult' does not change from @AsyncPending@ within
-- the specified delay, otherwise @Just asyncResult@ is returned. If you want
-- to wait/block on the 'AsyncResult' without the indirection of @Maybe@ then
-- consider using 'wait' or 'waitCheckTimeout' instead. 
waitTimeout :: (Serializable a) =>
               TimeInterval -> Async a -> Process (Maybe (AsyncResult a))
waitTimeout t hAsync =
  receiveChanTimeout (intervalToMs t) $ snd (channel hAsync)

-- | Cancel an asynchronous operation. To wait for cancellation to complete, use
-- 'cancelWait' instead.
cancel :: Async a -> Process ()
cancel (Async _ g _) = send g CancelWait

-- | Cancel an asynchronous operation and wait for the cancellation to complete.
-- Because of the asynchronous nature of message passing, the instruction to
-- cancel will race with the asynchronous worker, so it is /entirely possible/
-- that the 'AsyncResult' returned will not necessarily be 'AsyncCancelled'.
--
cancelWait :: (Serializable a) => Async a -> Process (AsyncResult a)
cancelWait hAsync = cancel hAsync >> wait hAsync 
