{-# LANGUAGE RankNTypes  #-}
module Control.Distributed.Process.Internal.Spawn
  ( spawn
  , spawnLink
  , spawnMonitor
  , call
  , spawnSupervised
  , spawnChannel
  ) where

import Control.Distributed.Static
  ( Static
  , Closure
  , closureCompose
  , staticClosure
  )
import Control.Distributed.Process.Internal.Types
  ( NodeId(..)
  , ProcessId(..)
  , Process(..)
  , MonitorRef(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , DidSpawn(..)
  , SendPort(..)
  , ReceivePort(..)
  , nullProcessId
  )
import Control.Distributed.Process.Serializable (Serializable, SerializableDict)
import Control.Distributed.Process.Internal.Closure.BuiltIn
  ( sdictSendPort
  , sndStatic
  , idCP
  , seqCP
  , bindCP
  , splitCP
  , cpLink
  , cpSend
  , cpNewChan
  , cpDelayed
  , returnCP
  , sdictUnit
  )
import Control.Distributed.Process.Internal.Primitives
  ( -- Basic messaging
    send
  , expect
  , receiveWait
  , match
  , matchIf
  , link
  , getSelfPid
  , monitor
  , monitorNode
  , unmonitor
  , spawnAsync
  , reconnect
  )

-- | Spawn a process
--
-- For more information about 'Closure', see
-- "Control.Distributed.Process.Closure".
--
-- See also 'call'.
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid proc = do
  us   <- getSelfPid
  mRef <- monitorNode nid
  sRef <- spawnAsync nid (cpDelayed us proc)
  receiveWait [
      matchIf (\(DidSpawn ref _) -> ref == sRef) $ \(DidSpawn _ pid) -> do
        unmonitor mRef
        send pid ()
        return pid
    , matchIf (\(NodeMonitorNotification ref _ _) -> ref == mRef) $ \_ ->
        return (nullProcessId nid)
    ]

-- | Spawn a process and link to it
--
-- Note that this is just the sequential composition of 'spawn' and 'link'.
-- (The "Unified" semantics that underlies Cloud Haskell does not even support
-- a synchronous link operation)
spawnLink :: NodeId -> Closure (Process ()) -> Process ProcessId
spawnLink nid proc = do
  pid <- spawn nid proc
  link pid
  return pid

-- | Like 'spawnLink', but monitor the spawned process
spawnMonitor :: NodeId -> Closure (Process ()) -> Process (ProcessId, MonitorRef)
spawnMonitor nid proc = do
  pid <- spawn nid proc
  ref <- monitor pid
  return (pid, ref)

-- | Run a process remotely and wait for it to reply
--
-- We monitor the remote process: if it dies before it can send a reply, we die
-- too.
--
-- For more information about 'Static', 'SerializableDict', and 'Closure', see
-- "Control.Distributed.Process.Closure".
--
-- See also 'spawn'.
call :: Serializable a
        => Static (SerializableDict a)
        -> NodeId
        -> Closure (Process a)
        -> Process a
call dict nid proc = do
  us <- getSelfPid
  (pid, mRef) <- spawnMonitor nid (proc `bindCP`
                                   cpSend dict us `seqCP`
                                   -- Delay so the process does not terminate
                                   -- before the response arrives.
                                   cpDelayed us (returnCP sdictUnit ())
                                  )
  mResult <- receiveWait
    [ match $ \a -> send pid () >> return (Right a)
    , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
              (\(ProcessMonitorNotification _ _ reason) -> return (Left reason))
    ]
  case mResult of
    Right a  -> do
      -- Wait for the monitor message so that we the mailbox doesn't grow
      receiveWait
        [ matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                  (\(ProcessMonitorNotification {}) -> return ())
        ]
      -- Clean up connection to pid
      reconnect pid
      return a
    Left err ->
      fail $ "call: remote process died: " ++ show err

-- | Spawn a child process, have the child link to the parent and the parent
-- monitor the child
spawnSupervised :: NodeId
                -> Closure (Process ())
                -> Process (ProcessId, MonitorRef)
spawnSupervised nid proc = do
  us   <- getSelfPid
  them <- spawn nid (cpLink us `seqCP` proc)
  ref  <- monitor them
  return (them, ref)

-- | Spawn a new process, supplying it with a new 'ReceivePort' and return
-- the corresponding 'SendPort'.
spawnChannel :: forall a. Serializable a => Static (SerializableDict a)
             -> NodeId
             -> Closure (ReceivePort a -> Process ())
             -> Process (SendPort a)
spawnChannel dict nid proc = do
    us <- getSelfPid
    _ <- spawn nid (go us)
    expect
  where
    go :: ProcessId -> Closure (Process ())
    go pid = cpNewChan dict
           `bindCP`
             (cpSend (sdictSendPort dict) pid `splitCP` proc)
           `bindCP`
             (idCP `closureCompose` staticClosure sndStatic)
