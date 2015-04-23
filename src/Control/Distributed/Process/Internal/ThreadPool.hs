-- | An implementation of a pool of threads
--
{-# LANGUAGE RecursiveDo #-}
module Control.Distributed.Process.Internal.ThreadPool
  ( newThreadPool
  , submitTask
  , lookupWorker
  , ThreadPool
  ) where

import Control.Exception
import Control.Monad
import Data.IORef
import qualified Data.Map as Map


-- | A pool of worker threads that execute tasks.
--
-- Each worker thread is named with a key @k@. Tasks are submitted to a
-- specific worker using its key. While the worker is busy the tasks are queued.
-- When there are no more queued tasks the worker ceases to exist.
--
-- The next time a task is submitted the worker will be respawned.
--
newtype ThreadPool k w = ThreadPool (IORef (Map.Map k (Maybe (IO ()), w)))

-- Each worker has an entry in the map with a closure that contains all
-- queued actions fot it.
--
-- No entry in the map is kept for defunct workers.

-- | Creates a pool with no workers.
newThreadPool :: IO (ThreadPool k w)
newThreadPool = fmap ThreadPool $ newIORef Map.empty

-- | @submitTask pool fork k task@ submits a task for the worker @k@.
--
-- If worker @k@ is busy, then the task is queued until the worker is available.
--
-- If worker @k@ does not exist, then the given @fork@ operation is used to
-- spawn the worker. @fork@ returns whatever information is deemed useful for
-- later retrieval via 'lookupWorker'.
--
submitTask :: Ord k
           => ThreadPool k w
           -> (IO () -> IO w)
           -> k -> IO () -> IO ()
submitTask (ThreadPool mapRef) fork k task = mdo
    m' <- join $ atomicModifyIORef mapRef $ \m ->
      case Map.lookup k m of
        -- There is no worker for this key, create one.
        Nothing -> ( m'
                   , do w <- fork $ flip onException terminateWorker $ do
                               task
                               continue
                        return $ Map.insert k (Nothing, w) m
                   )
        -- Queue an action for the existing worker.
        Just (mp, w) ->
          (m', return $ Map.insert k (Just $ maybe task (>> task) mp, w) m)
    return ()
  where
    continue = join $ atomicModifyIORef mapRef $ \m ->
      case Map.lookup k m of
        -- Execute the next batch of queued actions.
        Just (Just p, w)  -> (Map.insert k (Nothing, w) m, p >> continue)
        -- There are no more queued actions. Terminate the worker.
        Just (Nothing, w) -> (Map.delete k m, return ())
        -- The worker key was removed already (?)
        Nothing        -> (m, return ())
    -- Remove the worker key regardless of whether there are more queued
    -- actions.
    terminateWorker = atomicModifyIORef mapRef $ \m -> (Map.delete k m, ())

-- | Looks up a worker with the given key.
lookupWorker :: Ord k => ThreadPool k w -> k -> IO (Maybe w)
lookupWorker (ThreadPool mapRef) k =
    atomicModifyIORef mapRef $ \m -> (m, fmap snd $ Map.lookup k m)
