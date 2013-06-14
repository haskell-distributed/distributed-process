{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE DeriveGeneric             #-}

-- | Simple bounded (size) worker pool that accepts tasks and blocks
-- the caller until they've completed. Partly a /spike/ for that 'Task' API
-- and partly just a test bed for handling 'replyTo' in GenProcess.
--
module SimplePool
  ( Pool()
  , PoolSize
  , PoolStats(..)
  , start
  , pool
  , executeTask
  , stats
  ) where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Closure()
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
import qualified Control.Distributed.Process.Platform.ManagedProcess as ManagedProcess
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Data.Binary
import Data.List
  ( deleteBy
  , find
  )
import Data.Sequence
  ( Seq
  , ViewR(..)
  , (<|)
  , viewr
  )
import qualified Data.Sequence as Seq (empty, length)
import Data.Typeable

import GHC.Generics (Generic)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

type PoolSize = Int

data GetStats = GetStats
  deriving (Typeable, Generic)

instance Binary GetStats where

data PoolStats = PoolStats {
    maxJobs    :: Int
  , activeJobs :: Int
  , queuedJobs :: Int
  } deriving (Typeable, Generic)

instance Binary PoolStats where

data Pool a = Pool {
    poolSize :: PoolSize
  , active   :: [(MonitorRef, CallRef (Either String a), Async a)]
  , accepted :: Seq (CallRef (Either String a), Closure (Process a))
  } deriving (Typeable)

-- Client facing API

-- | Start a worker pool with an upper bound on the # of concurrent workers.
start :: forall a . (Serializable a)
         => Process (InitResult (Pool a))
         -> Process ()
start init' = ManagedProcess.serve () (\() -> init') poolServer
  where poolServer =
          defaultProcess {
              apiHandlers = [
                 handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
               , handleCall poolStatsRequest
               ]
            , infoHandlers = [ handleInfo taskComplete ]
            } :: ProcessDefinition (Pool a)

-- | Define a pool of a given size.
pool :: forall a . Serializable a
     => PoolSize
     -> Process (InitResult (Pool a))
pool sz' = return $ InitOk (Pool sz' [] Seq.empty) Infinity


-- enqueues the task in the pool and blocks
-- the caller until the task is complete
executeTask :: forall s a . (Addressable s, Serializable a)
            => s
            -> Closure (Process a)
            -> Process (Either String a)
executeTask sid t = call sid t

-- Fetch stats for the given server
stats :: forall s . Addressable s => s -> Process (Maybe PoolStats)
stats sid = tryCall sid GetStats

-- internal / server-side API

poolStatsRequest :: (Serializable a)
                 => Pool a
                 -> GetStats
                 -> Process (ProcessReply PoolStats (Pool a))
poolStatsRequest st GetStats =
  let sz = poolSize st
      ac = length (active st)
      pj = Seq.length (accepted st)
  in reply (PoolStats sz ac pj) st

-- /call/ handler: accept a task and defer responding until "later"
storeTask :: Serializable a
          => Pool a
          -> CallRef (Either String a)
          -> Closure (Process a)
          -> Process (ProcessReply (Either String a) (Pool a))
storeTask s r c = acceptTask s r c >>= noReply_

acceptTask :: Serializable a
           => Pool a
           -> CallRef (Either String a)
           -> Closure (Process a)
           -> Process (Pool a)
acceptTask s@(Pool sz' runQueue taskQueue) from task' =
  let currentSz = length runQueue
  in case currentSz >= sz' of
    True  -> do
      return $ s { accepted = enqueue taskQueue (from, task') }
    False -> do
      proc <- unClosure task'
      asyncHandle <- async proc
      ref <- monitorAsync asyncHandle
      taskEntry <- return (ref, from, asyncHandle)
      return s { active = (taskEntry:runQueue) }

-- /info/ handler: a worker has exited, process the AsyncResult and send a reply
-- to the waiting client (who is still stuck in 'call' awaiting a response).
taskComplete :: forall a . Serializable a
             => Pool a
             -> ProcessMonitorNotification
             -> Process (ProcessAction (Pool a))
taskComplete s@(Pool _ runQ _)
             (ProcessMonitorNotification ref _ _) =
  let worker = findWorker ref runQ in
  case worker of
    Just t@(_, c, h) -> wait h >>= respond c >> bump s t >>= continue
    Nothing          -> continue s

  where
    respond :: CallRef (Either String a)
            -> AsyncResult a
            -> Process ()
    respond c (AsyncDone       r) = replyTo c ((Right r) :: (Either String a))
    respond c (AsyncFailed     d) = replyTo c ((Left (show d)) :: (Either String a))
    respond c (AsyncLinkFailed d) = replyTo c ((Left (show d)) :: (Either String a))
    respond _      _              = die $ ExitOther "IllegalState"

    bump :: Pool a -> (MonitorRef, CallRef (Either String a), Async a) -> Process (Pool a)
    bump st@(Pool _ runQueue acc) worker =
      let runQ2 = deleteFromRunQueue worker runQueue
          accQ  = dequeue acc in
      case accQ of
        Nothing            -> return st { active = runQ2 }
        Just ((tr,tc), ts) -> acceptTask (st { accepted = ts, active = runQ2 }) tr tc

findWorker :: MonitorRef
           -> [(MonitorRef, CallRef (Either String a), Async a)]
           -> Maybe (MonitorRef, CallRef (Either String a), Async a)
findWorker key = find (\(ref,_,_) -> ref == key)

deleteFromRunQueue :: (MonitorRef, CallRef (Either String a), Async a)
                   -> [(MonitorRef, CallRef (Either String a), Async a)]
                   -> [(MonitorRef, CallRef (Either String a), Async a)]
deleteFromRunQueue c@(p, _, _) runQ = deleteBy (\_ (b, _, _) -> b == p) c runQ

{-# INLINE enqueue #-}
enqueue :: Seq a -> a -> Seq a
enqueue s a = a <| s

{-# INLINE dequeue #-}
dequeue :: Seq a -> Maybe (a, Seq a)
dequeue s = maybe Nothing (\(s' :> a) -> Just (a, s')) $ getR s

getR :: Seq a -> Maybe (ViewR a)
getR s =
  case (viewr s) of
    EmptyR -> Nothing
    a      -> Just a

