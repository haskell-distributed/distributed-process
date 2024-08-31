{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances     #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Extras.Internal.Primitives
-- Copyright   :  (c) Tim Watson 2013 - 2017, Parallel Scientific (Jeff Epstein) 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainers :  Jeff Epstein, Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a set of additional primitives that add functionality
-- to the basic Cloud Haskell APIs.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Extras.Internal.Primitives
  ( -- * General Purpose Process Addressing
    Addressable
  , Routable(..)
  , Resolvable(..)
  , Linkable(..)
  , Killable(..)
  , Monitored(..)

    -- * Spawning and Linking
  , spawnSignalled
  , spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure

    -- * Registered Processes
  , whereisRemote
  , whereisOrStart
  , whereisOrStartRemote

    -- * Selective Receive/Matching
  , matchCond
  , awaitResponse

    -- * General Utilities
  , times
  , monitor
  , awaitExit
  , isProcessAlive
  , forever'
  , deliver

    -- * Remote Table
  , __remoteTable
  ) where

import Control.Concurrent (myThreadId, throwTo)
import Control.Distributed.Process hiding (monitor, finally, catch)
import qualified Control.Distributed.Process as P (monitor, unmonitor)
import Control.Distributed.Process.Closure (seqCP, remotable, mkClosure)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Extras.Internal.Types
  ( Addressable
  , Linkable(..)
  , Killable(..)
  , Resolvable(..)
  , Routable(..)
  , Monitored(..)
  , RegisterSelf(..)
  , ExitReason(ExitOther)
  , whereisRemote
  )
import Control.Monad (void, (>=>), replicateM_)
import Control.Monad.Catch (finally, catchIf)
import Data.Maybe (isJust, fromJust)
import Data.Foldable (traverse_)

-- utility

-- | Monitor any @Resolvable@ object.
monitor :: Resolvable a => a -> Process (Maybe MonitorRef)
monitor = resolve >=> traverse P.monitor

-- | Wait until @Resolvable@ object will exit. Return immediately
-- if object can't be resolved.
awaitExit :: Resolvable a => a -> Process ()
awaitExit = resolve >=> traverse_ await where
  await pid = withMonitorRef pid $ \ref -> receiveWait
      [ matchIf (\(ProcessMonitorNotification r _ _) -> r == ref)
                (\_ -> return ())
      ]
  withMonitorRef pid = bracket (P.monitor pid) P.unmonitor

-- | Send message to @Addressable@ object.
deliver :: (Addressable a, Serializable m) => m -> a -> Process ()
deliver = flip sendTo

-- | Check if specified process is alive. Information may be outdated.
isProcessAlive :: ProcessId -> Process Bool
isProcessAlive pid = isJust <$> getProcessInfo pid

-- | Apply the supplied expression /n/ times
times :: Int -> Process () -> Process ()
times = replicateM_
{-# DEPRECATED times "use replicateM_ instead" #-}

-- | Like 'Control.Monad.forever' but sans space leak
forever' :: Monad m => m a -> m b
forever' a = let a' = a >> a' in a'
{-# INLINE forever' #-}

-- spawning, linking and generic server startup

-- | Spawn a new (local) process. This variant takes an initialisation
-- action and a secondary expression from the result of the initialisation
-- to @Process ()@. The spawn operation synchronises on the completion of the
-- @before@ action, such that the calling process is guaranteed to only see
-- the newly spawned @ProcessId@ once the initialisation has successfully
-- completed.
spawnSignalled :: Process a -> (a -> Process ()) -> Process ProcessId
spawnSignalled before after = do
  (sigStart, recvStart) <- newChan
  (pid, mRef) <- spawnMonitorLocal $ do
    initProc <- before
    sendChan sigStart ()
    after initProc
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
              (\(ProcessMonitorNotification _ _ dr) -> die $ ExitOther (show dr))
    , matchChan recvStart (\() -> return pid)
    ] `finally` (unmonitor mRef)

-- | Node local version of 'Control.Distributed.Process.spawnLink'.
-- Note that this is just the sequential composition of 'spawn' and 'link'.
-- (The "Unified" semantics that underlies Cloud Haskell does not even support
-- a synchronous link operation)
spawnLinkLocal :: Process () -> Process ProcessId
spawnLinkLocal p = do
  pid <- spawnLocal p
  link pid
  return pid

-- | Like 'spawnLinkLocal', but monitors the spawned process.
--
spawnMonitorLocal :: Process () -> Process (ProcessId, MonitorRef)
spawnMonitorLocal p = do
  pid <- spawnLocal p
  ref <- P.monitor pid
  return (pid, ref)

-- | CH's 'link' primitive, unlike Erlang's, will trigger when the target
-- process dies for any reason. This function has semantics like Erlang's:
-- it will trigger 'ProcessLinkException' only when the target dies abnormally.
--
linkOnFailure :: ProcessId -> Process ()
linkOnFailure them = do
  us <- getSelfPid
  tid <- liftIO $ myThreadId
  void $ spawnLocal $ do
    callerRef <- P.monitor us
    calleeRef <- P.monitor them
    reason <- receiveWait [
             matchIf (\(ProcessMonitorNotification mRef _ _) ->
                       mRef == callerRef) -- nothing left to do
                     (\_ -> return DiedNormal)
           , matchIf (\(ProcessMonitorNotification mRef' _ _) ->
                       mRef' == calleeRef)
                     (\(ProcessMonitorNotification _ _ r') -> return r')
         ]
    case reason of
      DiedNormal -> return ()
      _ -> liftIO $ throwTo tid (ProcessLinkException us reason)

-- | Returns the pid of the process that has been registered
-- under the given name. This refers to a local, per-node registration,
-- not @global@ registration. If that name is unregistered, a process
-- is started. This is a handy way to start per-node named servers.
--
whereisOrStart :: String -> Process () -> Process ProcessId
whereisOrStart name proc = do
  (sigStart, recvStart) <- newChan
  (_, mRef) <- spawnMonitorLocal $ do
    us <- getSelfPid
    catchIf (\(ProcessRegistrationException _ r) -> isJust r)
            (register name us >> sendChan sigStart us)
            (\(ProcessRegistrationException _ rPid) ->
                sendChan sigStart $ fromJust rPid)
    proc
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
              (\(ProcessMonitorNotification _ _ dr) -> die $ ExitOther (show dr))
    , matchChan recvStart return
    ] `finally` (unmonitor mRef)

-- | Helper function will register itself under a given name and send
-- result to given @Process@.
registerSelf :: (String, ProcessId) -> Process ()
registerSelf (name,target) =
  do self <- getSelfPid
     register name self
     send target (RegisterSelf, self)
     () <- expect
     return ()

$(remotable ['registerSelf])

-- | A remote equivalent of 'whereisOrStart'. It deals with the
-- node registry on the given node, and the process, if it needs to be started,
-- will run on that node. If the node is inaccessible, Nothing will be returned.
--
whereisOrStartRemote :: NodeId -> String -> Closure (Process ()) -> Process (Maybe ProcessId)
whereisOrStartRemote nid name proc =
     do mRef <- monitorNode nid
        whereisRemoteAsync nid name
        res <- receiveWait
          [ matchIf (\(WhereIsReply label _) -> label == name)
                    (\(WhereIsReply _ mPid) -> return (Just mPid)),
            matchIf (\(NodeMonitorNotification aref _ _) -> aref == mRef)
                    (\(NodeMonitorNotification _ _ _) -> return Nothing)
          ]
        case res of
           Nothing -> return Nothing
           Just (Just pid) -> unmonitor mRef >> return (Just pid)
           Just Nothing ->
              do self <- getSelfPid
                 sRef <- spawnAsync nid ($(mkClosure 'registerSelf) (name,self) `seqCP` proc)
                 ret <- receiveWait [
                      matchIf (\(NodeMonitorNotification ref _ _) -> ref == mRef)
                              (\(NodeMonitorNotification _ _ _) -> return Nothing),
                      matchIf (\(DidSpawn ref _) -> ref==sRef )
                              (\(DidSpawn _ pid) ->
                                  do pRef <- P.monitor pid
                                     receiveWait
                                       [ matchIf (\(RegisterSelf, apid) -> apid == pid)
                                                 (\(RegisterSelf, _) -> do unmonitor pRef
                                                                           send pid ()
                                                                           return $ Just pid),
                                         matchIf (\(NodeMonitorNotification aref _ _) -> aref == mRef)
                                                 (\(NodeMonitorNotification _aref _ _) -> return Nothing),
                                         matchIf (\(ProcessMonitorNotification ref _ _) -> ref==pRef)
                                                 (\(ProcessMonitorNotification _ _ _) -> return Nothing)
                                       ] )
                      ]
                 unmonitor mRef
                 case ret of
                   Nothing -> whereisOrStartRemote nid name proc
                   Just pid -> return $ Just pid

-- advanced messaging/matching

-- | An alternative to 'matchIf' that allows both predicate and action
-- to be expressed in one parameter.
matchCond :: (Serializable a) => (a -> Maybe (Process b)) -> Match b
matchCond cond =
   let v n = (isJust n, fromJust n)
       res = v . cond
    in matchIf (fst . res) (snd . res)

-- | Safe (i.e., monitored) waiting on an expected response/message.
awaitResponse :: Addressable a
              => a
              -> [Match (Either ExitReason b)]
              -> Process (Either ExitReason b)
awaitResponse addr matches = do
  mPid <- resolve addr
  case mPid of
    Nothing -> return $ Left $ ExitOther "UnresolvedAddress"
    Just p  ->
      bracket (P.monitor p)
              P.unmonitor
              $ \mRef -> receiveWait ((matchRef mRef):matches)
  where
    matchRef :: MonitorRef -> Match (Either ExitReason b)
    matchRef r = matchIf (\(ProcessMonitorNotification r' _ _) -> r == r')
                         (\(ProcessMonitorNotification _ _ d) -> do
                             return (Left (ExitOther (show d))))
