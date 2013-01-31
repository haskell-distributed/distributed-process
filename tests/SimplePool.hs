{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ScopedTypeVariables       #-}

-- | Simple bounded (size) worker pool that accepts tasks and blocks
-- the caller until they've completed. Partly a /spike/ for that 'Task' API
-- and partly just a test bed for handling 'replyTo' in GenProcess.
--
module SimplePool where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Closure()
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Control.Exception hiding (catch)
import Data.Binary()
import Data.List
  ( deleteBy
  , find
  )
import Data.Typeable

import Prelude hiding (catch)

type PoolSize = Int
type SimpleTask a = Closure (Process a)

data Pool a = Pool {
    poolSize :: PoolSize
  , active   :: [(MonitorRef, Recipient, Async a)]
  , accepted :: [(Recipient, Closure (Process a))]
  } deriving (Typeable)

poolServer :: forall a . (Serializable a) => ProcessDefinition (Pool a)
poolServer =
    defaultProcess {
        apiHandlers = [
            handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
        ]
      , infoHandlers = [
            handleInfo taskComplete
        ]
      } :: ProcessDefinition (Pool a)

-- | Start a worker pool with an upper bound on the # of concurrent workers.
simplePool :: forall a . (Serializable a)
              => PoolSize
              -> ProcessDefinition (Pool a)
              -> Process (Either (InitResult (Pool a)) TerminateReason)
simplePool sz server =
    start sz init' server
      `catch` (\(e :: SomeException) -> do
          say $ "terminating with " ++ (show e)
          liftIO $ throwIO e)
  where init' :: PoolSize -> Process (InitResult (Pool a))
        init' sz' = return $ InitOk (Pool sz' [] []) Infinity

-- enqueues the task in the pool and blocks
-- the caller until the task is complete
executeTask :: Serializable a
            => ProcessId
            -> Closure (Process a)
            -> Process (Either String a)
executeTask sid t = call sid t

-- /call/ handler: accept a task and defer responding until "later"
storeTask :: Serializable a
          => Pool a
          -> Recipient
          -> Closure (Process a)
          -> Process (ProcessReply (Pool a) ())
storeTask s r c = acceptTask s r c >>= noReply_

acceptTask :: Serializable a
           => Pool a
           -> Recipient
           -> Closure (Process a)
           -> Process (Pool a)
acceptTask s@(Pool sz' runQueue taskQueue) from task' =
  let currentSz = length runQueue
  in case currentSz >= sz' of
    True  -> do
      return $ s { accepted = ((from, task'):taskQueue) }
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
    respond :: Recipient
            -> AsyncResult a
            -> Process ()
    respond c (AsyncDone       r) = replyTo c ((Right r) :: (Either String a))
    respond c (AsyncFailed     d) = replyTo c ((Left (show d)) :: (Either String a))
    respond c (AsyncLinkFailed d) = replyTo c ((Left (show d)) :: (Either String a))
    respond _      _              = die $ TerminateOther "IllegalState"

    bump :: Pool a -> (MonitorRef, Recipient, Async a) -> Process (Pool a)
    bump st@(Pool _ runQueue acc) worker =
      let runQ2  = deleteFromRunQueue worker runQueue in
      case acc of
        []           -> return st { active = runQ2 }
        ((tr,tc):ts) -> acceptTask (st { accepted = ts, active = runQ2 }) tr tc

findWorker :: MonitorRef
           -> [(MonitorRef, Recipient, Async a)]
           -> Maybe (MonitorRef, Recipient, Async a)
findWorker key = find (\(ref,_,_) -> ref == key)

deleteFromRunQueue :: (MonitorRef, Recipient, Async a)
                   -> [(MonitorRef, Recipient, Async a)]
                   -> [(MonitorRef, Recipient, Async a)]
deleteFromRunQueue c@(p, _, _) runQ = deleteBy (\_ (b, _, _) -> b == p) c runQ

