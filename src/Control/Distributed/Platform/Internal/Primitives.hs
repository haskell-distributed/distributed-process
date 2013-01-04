-- | Common Entities used throughout -platform.
-- NB: Please DO NOT use this module as a dumping ground.
--
module Control.Distributed.Platform.Internal.Primitives
  ( spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure
  )
where

import Control.Distributed.Process
import Control.Concurrent (myThreadId, throwTo)
import Control.Monad (void)

-- | Node local version of 'Control.Distributed.Process.spawnLink'.
-- Note that this is just the sequential composition of 'spawn' and 'link'.
-- (The "Unified" semantics that underlies Cloud Haskell does not even support
-- a synchronous link operation)
spawnLinkLocal :: Process () -> Process ProcessId
spawnLinkLocal p = do
  pid <- spawnLocal p
  link pid
  return pid

-- | Like 'spawnLinkLocal', but monitor the spawned process
spawnMonitorLocal :: Process () -> Process (ProcessId, MonitorRef)
spawnMonitorLocal p = do
  pid <- spawnLocal p
  ref <- monitor pid
  return (pid, ref)

-- | CH's 'link' primitive, unlike Erlang's, will trigger when the target
-- process dies for any reason. linkOnFailure has semantics like Erlang's:
-- it will trigger only when the target function dies abnormally.
linkOnFailure :: ProcessId -> Process ()
linkOnFailure them = do
  us <- getSelfPid
  tid <- liftIO $ myThreadId
  void $ spawnLocal $ do
    callerRef <- monitor us
    calleeRef <- monitor them
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
