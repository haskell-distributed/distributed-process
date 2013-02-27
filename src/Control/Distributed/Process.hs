{- | [Cloud Haskell]

This is an implementation of Cloud Haskell, as described in
/Towards Haskell in the Cloud/ by Jeff Epstein, Andrew Black, and Simon
Peyton Jones (<http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/>),
although some of the details are different. The precise message passing
semantics are based on /A unified semantics for future Erlang/ by Hans
Svensson, Lars-Åke Fredlund and Clara Benac Earle.

For a detailed description of the package and other reference materials,
please see the distributed-process wiki page on github:
<https://github.com/haskell-distributed/distributed-process/wiki>.

-}
module Control.Distributed.Process
  ( -- * Basic types
    ProcessId
  , NodeId
  , Process
  , SendPortId
  , processNodeId
  , sendPortProcessId
  , liftIO -- Reexported for convenience
    -- * Basic messaging
  , send
  , expect
  , expectTimeout
    -- * Channels
  , ReceivePort
  , SendPort
  , sendPortId
  , newChan
  , sendChan
  , receiveChan
  , receiveChanTimeout
  , mergePortsBiased
  , mergePortsRR
    -- * Advanced messaging
  , Match
  , receiveWait
  , receiveTimeout
  , match
  , matchIf
  , matchUnknown
  , matchAny
  , matchAnyIf
  , matchChan
  , Message
  , matchMessage
  , matchMessageIf
  , wrapMessage
  , unwrapMessage
  , handleMessage
  , forward
  , delegate
  , relay
  , proxy
    -- * Process management
  , spawn
  , call
  , terminate
  , die
  , kill
  , exit
  , catchExit
  , catchesExit
  , ProcessTerminationException(..)
  , ProcessRegistrationException(..)
  , SpawnRef
  , getSelfPid
  , getSelfNode
  , ProcessInfo(..)
  , getProcessInfo
    -- * Monitoring and linking
  , link
  , linkNode
  , linkPort
  , unlink
  , unlinkNode
  , unlinkPort
  , monitor
  , monitorNode
  , monitorPort
  , unmonitor
  , withMonitor
  , MonitorRef -- opaque
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , DiedReason(..)
    -- * Closures
  , Closure
  , closure
  , Static
  , unStatic
  , unClosure
  , RemoteTable
    -- * Logging
  , say
    -- * Registry
  , register
  , reregister
  , unregister
  , whereis
  , nsend
  , registerRemoteAsync
  , reregisterRemoteAsync
  , unregisterRemoteAsync
  , whereisRemoteAsync
  , nsendRemote
  , WhereIsReply(..)
  , RegisterReply(..)
    -- * Exception handling
  , catch
  , Handler(..)
  , catches
  , try
  , mask
  , onException
  , bracket
  , bracket_
  , finally
    -- * Auxiliary API
  , spawnAsync
  , spawnSupervised
  , spawnLink
  , spawnMonitor
  , spawnChannel
  , DidSpawn(..)
    -- * Local versions of 'spawn'
  , spawnLocal
  , spawnChannelLocal
    -- * Reconnecting
  , reconnect
  , reconnectPort
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Data.Typeable (Typeable)
import Control.Monad.IO.Class (liftIO)
import Control.Applicative ((<$>))
import Control.Monad.Reader (ask)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Control.Distributed.Static
  ( Closure
  , closure
  , Static
  , RemoteTable
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
  , PortMonitorNotification(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , ProcessRegistrationException(..)
  , DiedReason(..)
  , SpawnRef(..)
  , DidSpawn(..)
  , SendPort(..)
  , ReceivePort(..)
  , SendPortId(..)
  , WhereIsReply(..)
  , RegisterReply(..)
  , LocalProcess(processNode)
  , Message
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
  , cpDelay
  )
import Control.Distributed.Process.Internal.Primitives
  ( -- Basic messaging
    send
  , expect
    -- Channels
  , newChan
  , sendChan
  , receiveChan
  , mergePortsBiased
  , mergePortsRR
    -- Advanced messaging
  , Match
  , receiveWait
  , receiveTimeout
  , match
  , matchIf
  , matchUnknown
  , matchAny
  , matchAnyIf
  , matchChan
  , matchMessage
  , matchMessageIf
  , wrapMessage
  , unwrapMessage
  , handleMessage
  , forward
  , delegate
  , relay
  , proxy
    -- Process management
  , terminate
  , ProcessTerminationException(..)
  , die
  , exit
  , catchExit
  , catchesExit
  , kill
  , getSelfPid
  , getSelfNode
  , ProcessInfo(..)
  , getProcessInfo
    -- Monitoring and linking
  , link
  , linkNode
  , linkPort
  , unlink
  , unlinkNode
  , unlinkPort
  , monitor
  , monitorNode
  , monitorPort
  , unmonitor
  , withMonitor
    -- Logging
  , say
    -- Registry
  , register
  , reregister
  , unregister
  , whereis
  , nsend
  , registerRemoteAsync
  , reregisterRemoteAsync
  , unregisterRemoteAsync
  , whereisRemoteAsync
  , nsendRemote
    -- Closures
  , unStatic
  , unClosure
    -- Exception handling
  , catch
  , Handler(..)
  , catches
  , try
  , mask
  , onException
  , bracket
  , bracket_
  , finally
    -- Auxiliary API
  , expectTimeout
  , receiveChanTimeout
  , spawnAsync
    -- Reconnecting
  , reconnect
  , reconnectPort
  )
import Control.Distributed.Process.Node (forkProcess)

-- INTERNAL NOTES
--
-- 1.  'send' never fails. If you want to know that the remote process received
--     your message, you will need to send an explicit acknowledgement. If you
--     want to know when the remote process failed, you will need to monitor
--     that remote process.
--
-- 2.  'send' may block (when the system TCP buffers are full, while we are
--     trying to establish a connection to the remote endpoint, etc.) but its
--     return does not imply that the remote process received the message (much
--     less processed it). When 'send' targets a local process, it is dispatched
--     via the node controller however, in which cases it will /not/ block. This
--     isn't part of the semantics, so it should be ok. The ordering is maintained
--     because the ctrlChannel still has FIFO semantics with regards interactions
--     between two disparate forkIO threads.
--
-- 3.  Message delivery is reliable and ordered. That means that if process A
--     sends messages m1, m2, m3 to process B, B will either arrive all three
--     messages in order (m1, m2, m3) or a prefix thereof; messages will not be
--     'missing' (m1, m3) or reordered (m1, m3, m2)
--
-- In order to guarantee (3), we stipulate that
--
-- 3a. We do not garbage collect connections because Network.Transport provides
--     ordering guarantees only *per connection*.
--
-- 3b. Once a connection breaks, we have no way of knowing which messages
--     arrived and which did not; hence, once a connection fails, we assume the
--     remote process to be forever unreachable. Otherwise we might sent m1 and
--     m2, get notified of the broken connection, reconnect, send m3, but only
--     m1 and m3 arrive.
--
-- 3c. As a consequence of (3b) we should not reuse PIDs. If a process dies,
--     we consider it forever unreachable. Hence, new processes should get new
--     IDs or they too would be considered unreachable.
--
-- Main reference for Cloud Haskell is
--
-- [1] "Towards Haskell in the Cloud", Jeff Epstein, Andrew Black and Simon
--     Peyton-Jones.
--       http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
--
-- The precise semantics for message passing is based on
--
-- [2] "A Unified Semantics for Future Erlang", Hans Svensson, Lars-Ake Fredlund
--     and Clara Benac Earle (not freely available online, unfortunately)
--
-- Some pointers to related documentation about Erlang, for comparison and
-- inspiration:
--
-- [3] "Programming Distributed Erlang Applications: Pitfalls and Recipes",
--     Hans Svensson and Lars-Ake Fredlund
--       http://man.lupaworld.com/content/develop/p37-svensson.pdf
-- [4] The Erlang manual, sections "Message Sending" and "Send"
--       http://www.erlang.org/doc/reference_manual/processes.html#id82409
--       http://www.erlang.org/doc/reference_manual/expressions.html#send
-- [5] Questions "Is the order of message reception guaranteed?" and
--     "If I send a message, is it guaranteed to reach the receiver?" of
--     the Erlang FAQ
--       http://www.erlang.org/faq/academic.html
-- [6] "Delivery of Messages", post on erlang-questions
--       http://erlang.org/pipermail/erlang-questions/2012-February/064767.html

--------------------------------------------------------------------------------
-- Primitives are defined in a separate module; here we only define derived   --
-- constructs                                                                 --
--------------------------------------------------------------------------------

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
  sRef <- spawnAsync nid (cpDelay us proc)
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
  (pid, mRef) <- spawnMonitor nid (proc `bindCP` cpSend dict us)
  -- We are guaranteed to receive the reply before the monitor notification
  -- (if a reply is sent at all)
  -- NOTE: This might not be true if we switch to unreliable delivery.
  mResult <- receiveWait
    [ match (return . Right)
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
spawnChannel :: forall a. Typeable a => Static (SerializableDict a)
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

--------------------------------------------------------------------------------
-- Local versions of spawn                                                    --
--------------------------------------------------------------------------------

-- | Spawn a process on the local node
spawnLocal :: Process () -> Process ProcessId
spawnLocal proc = do
  node <- processNode <$> ask
  liftIO $ forkProcess node proc

-- | Create a new typed channel, spawn a process on the local node, passing it
-- the receive port, and return the send port
spawnChannelLocal :: Serializable a
                  => (ReceivePort a -> Process ())
                  -> Process (SendPort a)
spawnChannelLocal proc = do
  node <- processNode <$> ask
  liftIO $ do
    mvar <- newEmptyMVar
    _ <- forkProcess node $ do
      -- It is important that we allocate the new channel in the new process,
      -- because otherwise it will be associated with the wrong process ID
      (sport, rport) <- newChan
      liftIO $ putMVar mvar sport
      proc rport
    takeMVar mvar
