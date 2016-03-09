-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Async
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This API provides a means for spawning asynchronous operations, waiting
-- for their results, cancelling them and various other utilities.
-- Asynchronous operations can be executed on remote nodes.
--
-- [Asynchronous Operations]
--
-- There is an implicit contract for async workers; Workers must exit
-- normally (i.e., should not call the 'exit', 'die' or 'terminate'
-- Cloud Haskell primitives), otherwise the 'AsyncResult' will end up being
-- @AsyncFailed DiedException@ instead of containing the result.
--
-- Portions of this file are derived from the @Control.Concurrent.Async@
-- module, from the @async@ package written by Simon Marlow.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Async
  ( -- * Exported types
    AsyncRef
  , AsyncTask(..)
  , Async
  , AsyncResult(..)
    -- * Spawning asynchronous operations
  , async
  , asyncLinked
  , task
  , remoteTask
  , monitorAsync
    -- * Cancelling asynchronous operations
  , cancel
  , cancelWait
  , cancelWith
  , cancelKill
    -- * Querying for results
  , poll
  , check
  , wait
  , waitAny
    -- * Waiting with timeouts
  , waitAnyTimeout
  , waitTimeout
  , waitCancelTimeout
  , waitCheckTimeout
    -- * STM versions
  , pollSTM
  , waitTimeoutSTM
  , waitAnyCancel
  , waitEither
  , waitEither_
  , waitBoth
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Control.Applicative
import Control.Concurrent.STM hiding (check)
import Control.Distributed.Process hiding (catch)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Async.Internal.Types
import Control.Distributed.Process.Extras
  ( CancelWait(..)
  , Channel
  , Resolvable(..)
  )
import Control.Distributed.Process.Extras.Time
  ( asTimeout
  , TimeInterval
  )
import Control.Monad
import Data.Maybe
  ( fromMaybe
  )

import System.Timeout (timeout)

-- | Wraps a regular @Process a@ as an 'AsyncTask'.
task :: Process a -> AsyncTask a
task = AsyncTask

-- | Wraps the components required and builds a remote 'AsyncTask'.
remoteTask :: Static (SerializableDict a)
              -> NodeId
              -> Closure (Process a)
              -> AsyncTask a
remoteTask = AsyncRemoteTask

-- | Given an 'Async' handle, monitor the worker process.
monitorAsync :: Async a -> Process MonitorRef
monitorAsync hAsync = do
  worker <- resolve hAsync
  case worker of
    Nothing -> die "Invalid Async Handle"
    Just p  -> monitor p

-- | Spawns an asynchronous action and returns a handle to it,
-- which can be used to obtain its status and/or result or interact
-- with it (using the API exposed by this module).
--
async :: (Serializable a) => AsyncTask a -> Process (Async a)
async = asyncDo False

-- | This is a useful variant of 'async' that ensures an @Async@ task is
-- never left running unintentionally. We ensure that if the caller's process
-- exits, that the worker is killed.
--
-- There is currently a contract for async workers, that they should
-- exit normally (i.e., they should not call the @exit@ or @kill@ with their own
-- 'ProcessId' nor use the @terminate@ primitive to cease functining), otherwise
-- the 'AsyncResult' will end up being @AsyncFailed DiedException@ instead of
-- containing the desired result.
--
asyncLinked :: (Serializable a) => AsyncTask a -> Process (Async a)
asyncLinked = asyncDo True

-- private API
asyncDo :: (Serializable a) => Bool -> AsyncTask a -> Process (Async a)
asyncDo shouldLink (AsyncRemoteTask d n c) =
  let proc = call d n c in asyncDo shouldLink AsyncTask { asyncTask = proc }
asyncDo shouldLink (AsyncTask proc) = do
    root <- getSelfPid
    result <- liftIO $ newEmptyTMVarIO
    sigStart <- liftIO $ newEmptyTMVarIO
    (sp, rp) <- newChan

    -- listener/response proxy
    insulator <- spawnLocal $ do
        worker <- spawnLocal $ do
            liftIO $ atomically $ takeTMVar sigStart
            r <- proc
            void $ liftIO $ atomically $ putTMVar result (AsyncDone r)

        sendChan sp worker  -- let the parent process know the worker pid

        wref <- monitor worker
        rref <- case shouldLink of
                    True  -> monitor root >>= return . Just
                    False -> return Nothing
        finally (pollUntilExit worker result)
                (unmonitor wref >>
                    return (maybe (return ()) unmonitor rref))

    workerPid <- receiveChan rp
    liftIO $ atomically $ putTMVar sigStart ()

    return Async {
          _asyncWorker  = workerPid
        , _asyncMonitor = insulator
        , _asyncWait    = (readTMVar result)
        }

  where
    pollUntilExit :: (Serializable a)
                  => ProcessId
                  -> TMVar (AsyncResult a)
                  -> Process ()
    pollUntilExit wpid result' = do
      r <- receiveWait [
          match (\c@(CancelWait) -> kill wpid "cancel" >> return (Left c))
        , match (\(ProcessMonitorNotification _ pid' r) ->
                  return (Right (pid', r)))
        ]
      case r of
          Left CancelWait
            -> liftIO $ atomically $ putTMVar result' AsyncCancelled
          Right (fpid, d)
            | fpid == wpid
              -> case d of
                     DiedNormal -> return ()
                     _          -> liftIO $ atomically $ putTMVar result' (AsyncFailed d)
            | otherwise -> kill wpid "linkFailed"

-- | Check whether an 'Async' has completed yet.
--
-- See "Control.Distributed.Process.Platform.Async".
poll :: (Serializable a) => Async a -> Process (AsyncResult a)
poll hAsync = do
  r <- liftIO $ atomically $ pollSTM hAsync
  return $ fromMaybe (AsyncPending) r

-- | Like 'poll' but returns 'Nothing' if @(poll hAsync) == AsyncPending@.
--
-- See "Control.Distributed.Process.Platform.Async".
check :: (Serializable a) => Async a -> Process (Maybe (AsyncResult a))
check hAsync = poll hAsync >>= \r -> case r of
  AsyncPending -> return Nothing
  ar           -> return (Just ar)

-- | Wait for an asynchronous operation to complete or timeout.
--
-- See "Control.Distributed.Process.Platform.Async".
waitCheckTimeout :: (Serializable a) =>
                    TimeInterval -> Async a -> Process (AsyncResult a)
waitCheckTimeout t hAsync =
  waitTimeout t hAsync >>= return . fromMaybe (AsyncPending)

-- | Wait for an asynchronous action to complete, and return its
-- value. The result (which can include failure and/or cancellation) is
-- encoded by the 'AsyncResult' type.
--
-- @wait = liftIO . atomically . waitSTM@
--
-- See "Control.Distributed.Process.Platform.Async".
{-# INLINE wait #-}
wait :: Async a -> Process (AsyncResult a)
wait = liftIO . atomically . waitSTM

-- | Wait for an asynchronous operation to complete or timeout.
--
-- See "Control.Distributed.Process.Platform.Async".
waitTimeout :: (Serializable a) =>
               TimeInterval -> Async a -> Process (Maybe (AsyncResult a))
waitTimeout t hAsync = do
  -- This is not the most efficient thing to do, but it's the most erlang-ish.
  (sp, rp) <- newChan :: (Serializable a) => Process (Channel (AsyncResult a))
  pid <- spawnLocal $ wait hAsync >>= sendChan sp
  receiveChanTimeout (asTimeout t) rp `finally` kill pid "timeout"

-- | Wait for an asynchronous operation to complete or timeout.
-- If it times out, then 'cancelWait' the async handle.
--
waitCancelTimeout :: (Serializable a)
                  => TimeInterval
                  -> Async a
                  -> Process (AsyncResult a)
waitCancelTimeout t hAsync = do
  r <- waitTimeout t hAsync
  case r of
    Nothing -> cancelWait hAsync
    Just ar -> return ar

-- | As 'waitTimeout' but uses STM directly, which might be more efficient.
waitTimeoutSTM :: (Serializable a)
                 => TimeInterval
                 -> Async a
                 -> Process (Maybe (AsyncResult a))
waitTimeoutSTM t hAsync =
  let t' = (asTimeout t)
  in liftIO $ timeout t' $ atomically $ waitSTM hAsync

-- | Wait for any of the supplied @Async@s to complete. If multiple
-- 'Async's complete, then the value returned corresponds to the first
-- completed 'Async' in the list.
--
-- NB: Unlike @AsyncChan@, 'Async' does not discard its 'AsyncResult' once
-- read, therefore the semantics of this function are different to the
-- former. Specifically, if @asyncs = [a1, a2, a3]@ and @(AsyncDone _) = a1@
-- then the remaining @a2, a3@ will never be returned by 'waitAny'.
--
waitAny :: (Serializable a)
        => [Async a]
        -> Process (Async a, AsyncResult a)
waitAny asyncs = do
  r <- liftIO $ waitAnySTM asyncs
  return r

-- | Like 'waitAny', but also cancels the other asynchronous
-- operations as soon as one has completed.
--
waitAnyCancel :: (Serializable a)
              => [Async a] -> Process (Async a, AsyncResult a)
waitAnyCancel asyncs =
  waitAny asyncs `finally` mapM_ cancel asyncs

-- | Wait for the first of two @Async@s to finish.
--
waitEither :: Async a
              -> Async b
              -> Process (Either (AsyncResult a) (AsyncResult b))
waitEither left right =
  liftIO $ atomically $
    (Left  <$> waitSTM left)
      `orElse`
    (Right <$> waitSTM right)

-- | Like 'waitEither', but the result is ignored.
--
waitEither_ :: Async a -> Async b -> Process ()
waitEither_ left right =
  liftIO $ atomically $
    (void $ waitSTM left)
      `orElse`
    (void $ waitSTM right)

-- | Waits for both @Async@s to finish.
--
waitBoth :: Async a
            -> Async b
            -> Process ((AsyncResult a), (AsyncResult b))
waitBoth left right =
  liftIO $ atomically $ do
    a <- waitSTM left
           `orElse`
         (waitSTM right >> retry)
    b <- waitSTM right
    return (a,b)

-- | Like 'waitAny' but times out after the specified delay.
waitAnyTimeout :: (Serializable a)
               => TimeInterval
               -> [Async a]
               -> Process (Maybe (AsyncResult a))
waitAnyTimeout delay asyncs =
  let t' = asTimeout delay
  in liftIO $ timeout t' $ do
    r <- waitAnySTM asyncs
    return $ snd r

-- | Cancel an asynchronous operation.
--
-- See "Control.Distributed.Process.Platform.Async".
cancel :: Async a -> Process ()
cancel (Async _ g _) = send g CancelWait

-- | Cancel an asynchronous operation and wait for the cancellation to complete.
--
-- See "Control.Distributed.Process.Platform.Async".
cancelWait :: (Serializable a) => Async a -> Process (AsyncResult a)
cancelWait hAsync = cancel hAsync >> wait hAsync

-- | Cancel an asynchronous operation immediately.
--
-- See "Control.Distributed.Process.Platform.Async".
cancelWith :: (Serializable b) => b -> Async a -> Process ()
cancelWith reason hAsync = do
  worker <- resolve hAsync
  case worker of
    Nothing  -> die "Invalid Async Handle"
    Just ref -> exit ref reason

-- | Like 'cancelWith' but sends a @kill@ instruction instead of an exit.
--
-- See 'Control.Distributed.Process.Platform.Async'.
cancelKill :: String -> Async a -> Process ()
cancelKill reason hAsync = do
  worker <- resolve hAsync
  case worker of
    Nothing  -> die "Invalid Async Handle"
    Just ref -> kill ref reason

--------------------------------------------------------------------------------
-- STM Specific API                                                           --
--------------------------------------------------------------------------------

-- | STM version of 'waitAny'.
waitAnySTM :: [Async a] -> IO (Async a, AsyncResult a)
waitAnySTM asyncs =
  atomically $
    foldr orElse retry $
      map (\a -> do r <- waitSTM a; return (a, r)) asyncs

-- | A version of 'wait' that can be used inside an STM transaction.
--
waitSTM :: Async a -> STM (AsyncResult a)
waitSTM (Async _ _ w) = w

-- | A version of 'poll' that can be used inside an STM transaction.
--
{-# INLINE pollSTM #-}
pollSTM :: Async a -> STM (Maybe (AsyncResult a))
pollSTM (Async _ _ w) = (Just <$> w) `orElse` return Nothing
