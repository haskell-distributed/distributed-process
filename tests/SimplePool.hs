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

import Control.Distributed.Process
import Control.Distributed.Process.Closure()
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.GenProcess
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable

import Data.Binary()
import Data.List
  ( deleteBy
  , find
  )
import Data.Typeable

type PoolSize = Int
type SimpleTask a = Closure (Process a)

data State a = State {
    poolSize :: PoolSize
  , active   :: [(ProcessId, Recipient, Async a)]
  , accepted :: [(Recipient, Closure (Process a))]
  } deriving (Typeable)

-- | Start a worker pool with an upper bound on the # of concurrent workers.
simplePool :: forall a . (Serializable a)
              => PoolSize
              -> Process (Either (InitResult (State a)) TerminateReason)
simplePool sz =
  let server = defaultProcess {
          dispatchers = [
            handleCallFrom (\s f (p :: Closure (Process a)) -> acceptTask s f p)
          ]
        } :: ProcessDefinition (State a)
  in start sz init' server
  where init' :: PoolSize -> Process (InitResult (State a))
        init' sz' = return $ InitOk (State sz' [] []) Infinity

-- /call/ handler: accept a task and defer responding until "later"
acceptTask :: Serializable a
           => State a
           -> Recipient
           -> Closure (Process a)
           -> Process (ProcessReply (State a) ())
acceptTask s@(State sz' runQueue taskQueue) from task' =
  let currentSz = length runQueue
  in case currentSz >= sz' of
    True  -> do
      s2 <- return $ s{ accepted = ((from, task'):taskQueue) }
      noReply_ s2
    False -> do
      proc <- unClosure task'
      asyncHandle <- async proc
      pid <- return $ asyncWorker asyncHandle
      taskEntry <- return (pid, from, asyncHandle)
      _ <- monitor pid 
      noReply_ s { accepted = ((from, task'):taskQueue)
                 , active   = (taskEntry:runQueue)
                 }

-- /info/ handler: a worker has exited, process the AsyncResult and send a reply
-- to the waiting client (who is still stuck in 'call' awaiting a response).
taskComplete :: forall a . Serializable a
             => State a
             -> ProcessMonitorNotification
             -> Process (ProcessAction (State a))
taskComplete s@(State _ runQ _)
             (ProcessMonitorNotification _ pid _) =
  let worker = findWorker pid runQ in
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
    
    bump :: State a -> (ProcessId, Recipient, Async a) -> Process (State a)
    bump (State maxSz runQueue taskQueue) c@(pid', _, _) =
      let runLen   = (length runQueue) - 1
          _runQ2   = deleteBy (\_ (b, _, _) -> b == pid') c runQ
          slots    = maxSz - runLen
          runnable = ((length taskQueue > 0) && (slots > 0)) in
      case runnable of
          True  -> {- pull `slots' tasks over to the run queue -} die $ "WHAT!"
          False -> die $ "oh, that!"
          
          -- take this task out of the run queue and bump pending tasks if needed
          -- deleteBy :: (a -> a -> Bool) -> a -> [a] -> [a]

findWorker :: ProcessId
           -> [(ProcessId, Recipient, Async a)]
           -> Maybe (ProcessId, Recipient, Async a)
findWorker key = find (\(pid,_,_) -> pid == key)
