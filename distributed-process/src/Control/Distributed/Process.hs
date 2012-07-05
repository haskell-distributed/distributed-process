-- | [Cloud Haskell]
-- 
-- This is an implementation of Cloud Haskell, as described in 
-- /Towards Haskell in the Cloud/ by Jeff Epstein, Andrew Black, and Simon
-- Peyton Jones
-- (<http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/>),
-- although some of the details are different. The precise message passing
-- semantics are based on /A unified semantics for future Erlang/ by	Hans
-- Svensson, Lars-Åke Fredlund and Clara Benac Earle.
module Control.Distributed.Process 
  ( -- * Basic types 
    ProcessId
  , NodeId
  , Process
  , SendPortId
    -- * Basic messaging
  , send 
  , expect
    -- * Channels
  , ReceivePort
  , SendPort
  , sendPortId
  , newChan
  , sendChan
  , receiveChan
  , mergePortsBiased
  , mergePortsRR
    -- * Advanced messaging
  , Match
  , receiveWait
  , receiveTimeout
  , match
  , matchIf
  , matchUnknown
    -- * Process management
  , spawn
  , call
  , terminate
  , ProcessTerminationException(..)
  , SpawnRef
  , getSelfPid
  , getSelfNode
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
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , MonitorRef -- opaque
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , DiedReason(..)
    -- * Closures
  , Closure
  , Static
  , unClosure
  , RemoteTable
    -- * Registry
  , register
  , unregister
  , whereis
  , nsend
  , registerRemote
  , unregisterRemote
  , whereisRemote
  , nsendRemote
    -- * Auxiliary API
  , catch
  , expectTimeout
  , spawnAsync
  , spawnSupervised
  , spawnLink
  , spawnMonitor
  , DidSpawn(..)
  ) where

import Prelude hiding (catch)
import Data.Typeable (Typeable, typeOf)
import Control.Applicative ((<$>))
import Control.Exception (throw)
import Control.Distributed.Process.Internal.MessageT (getLocalNode)
import Control.Distributed.Process.Internal.Dynamic (fromDyn, dynTypeRep)
import Control.Distributed.Process.Internal.Types 
  ( RemoteTable
  , NodeId(..)
  , ProcessId(..)
  , Process(..)
  , Closure(..)
  , Static(..)
  , MonitorRef(..)
  , ProcessMonitorNotification(..)
  , NodeMonitorNotification(..)
  , PortMonitorNotification(..)
  , ProcessLinkException(..)
  , NodeLinkException(..)
  , PortLinkException(..)
  , DiedReason(..)
  , SpawnRef(..)
  , DidSpawn(..)
  , Closure(..)
  , SendPort(..)
  , ReceivePort(..)
  , SerializableDict(..)
  , procMsg
  , LocalNode(..)
  , SendPortId
  )
import Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( linkClosure
  , unlinkClosure
  , sendClosure
  , expectClosure
  , serializableDictUnit
  )
import Control.Distributed.Process.Internal.Closure.Combinators (cpSeq, cpBind)
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
    -- Process management
  , terminate
  , ProcessTerminationException(..)
  , getSelfPid
  , getSelfNode
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
    -- Registry
  , register
  , unregister
  , whereis
  , nsend
  , registerRemote
  , unregisterRemote
  , whereisRemote
  , nsendRemote
    -- Auxiliary API
  , catch
  , expectTimeout
  , spawnAsync
  )
import Control.Distributed.Process.Internal.Closure (resolveClosure)

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
--     less processed it)
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
spawn :: NodeId -> Closure (Process ()) -> Process ProcessId
spawn nid proc = do
  us   <- getSelfPid
  -- Since we throw an exception when the remote node dies, we could use
  -- linkNode instead. However, we don't have a way of "scoped" linking so if
  -- we call linkNode here, and unlinkNode after, then we might remove a link
  -- that was already set up
  mRef <- monitorNode nid
  sRef <- spawnAsync nid $ linkClosure us 
                   `cpSeq` expectClosure serializableDictUnit
                   `cpSeq` unlinkClosure us
                   `cpSeq` proc
  mPid <- receiveWait 
    [ matchIf (\(DidSpawn ref _) -> ref == sRef)
              (\(DidSpawn _ pid) -> return $ Just pid)
    , matchIf (\(NodeMonitorNotification ref _ _) -> ref == mRef)
              (\_ -> return Nothing)
    ]
  unmonitor mRef
  case mPid of
    Nothing  -> fail "spawn: remote node failed"
    Just pid -> send pid () >> return pid

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
-- We link to the remote process, so that if it dies, we die too.
call :: SerializableDict a -> NodeId -> Closure (Process a) -> Process a
call sdict@SerializableDict nid proc = do 
  us <- getSelfPid
  _  <- spawnLink nid (proc `cpBind` sendClosure sdict us)
  expect

-- | Spawn a child process, have the child link to the parent and the parent
-- monitor the child
spawnSupervised :: NodeId 
                -> Closure (Process ()) 
                -> Process (ProcessId, MonitorRef)
spawnSupervised nid proc = do
  us   <- getSelfPid
  them <- spawn nid (linkClosure us `cpSeq` proc) 
  ref  <- monitor them
  return (them, ref)

-- | Deserialize a closure
unClosure :: forall a. Typeable a => Closure a -> Process a
unClosure (Closure (Static label) env) = do
    rtable <- remoteTable <$> procMsg getLocalNode 
    case resolveClosure rtable label env of
      Nothing  -> throw . userError $ "Unregistered closure " ++ show label
      Just dyn -> return $ fromDyn dyn (throw (typeError dyn))
  where
    typeError dyn = userError $ "lookupStatic type error: " 
                 ++ "cannot match " ++ show (dynTypeRep dyn) 
                 ++ " against " ++ show (typeOf (undefined :: a))
