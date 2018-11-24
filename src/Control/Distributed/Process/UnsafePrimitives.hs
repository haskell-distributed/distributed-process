-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.UnsafePrimitives
-- Copyright   :  (c) Well-Typed / Tim Watson
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- [Unsafe Variants of Cloud Haskell's Messaging Primitives]
--
-- Cloud Haskell's semantics do not mention evaluation/strictness properties
-- at all; Only the promise (or lack) of signal/message delivery between
-- processes is considered. For practical purposes, Cloud Haskell optimises
-- communication between (intra-node) local processes by skipping the
-- network-transport layer. In order to ensure the same strictness semantics
-- however, messages /still/ undergo binary serialisation before (internal)
-- transmission takes place. Thus we ensure that in both (the local and remote)
-- cases, message payloads are fully evaluated. Whilst this provides the user
-- with /unsurprising/ behaviour, the resulting performance overhead is quite
-- severe. Communicating data between Haskell threads /without/ forcing binary
-- serialisation reduces (intra-node, inter-process) communication overheads
-- by several orders of magnitude.
--
-- This module provides variants of Cloud Haskell's messaging primitives
-- ('send', 'sendChan', 'nsend' and 'wrapMessage') which do /not/ force binary
-- serialisation in the local case, thereby offering superior intra-node
-- messaging performance. The /catch/ is that any evaluation problems lurking
-- within the passed data structure (e.g., fields set to @undefined@ and so on)
-- will show up in the receiver rather than in the caller (as they would with
-- the /normal/ strategy).
--
-- Use of the functions in this module can potentially change the runtime
-- behaviour of your application. In addition, messages passed between Cloud
-- Haskell processes are written to a tracing infrastructure on the local node,
-- to provide improved introspection and debugging facilities for complex actor
-- based systems. This module makes no attempt to force evaluation in these
-- cases either, thus evaluation problems in passed data structures could not
-- only crash your processes, but could also bring down critical internal
-- services on which the node relies to function correctly.
--
-- If you wish to repudiate such issues, you are advised to consider the use
-- of NFSerialisable in the distributed-process-extras package, which type
-- class brings NFData into scope along with Serializable, such that we can
-- force evaluation. Intended for use with modules such as this one, this
-- approach guarantees correct evaluatedness in terms of @NFData@. Please note
-- however, that we /cannot/ guarantee that an @NFData@ instance will behave the
-- same way as a @Binary@ one with regards evaluation, so it is still possible
-- to introduce unexpected behaviour by using /unsafe/ primitives in this way.
--
-- You have been warned!
--
-- This module is exported so that you can replace the use of Cloud Haskell's
-- /safe/ messaging primitives. If you want to use both variants, then you can
-- take advantage of qualified imports, however "Control.Distributed.Process"
-- also re-exports these functions under different names, using the @unsafe@
-- prefix.
--
module Control.Distributed.Process.UnsafePrimitives
  ( -- * Unsafe Basic Messaging
    send
  , sendChan
  , nsend
  , nsendRemote
  , usend
  , wrapMessage
  ) where

import Control.Distributed.Process.Internal.Messaging
  ( sendMessage
  , sendBinary
  , sendCtrlMsg
  )
import Control.Distributed.Process.Management.Internal.Types
  ( MxEvent(..)
  )
import Control.Distributed.Process.Management.Internal.Trace.Types
  ( traceEvent
  )
import Control.Distributed.Process.Internal.Types
  ( ProcessId(..)
  , NodeId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , SendPort(..)
  , ProcessSignal(..)
  , Identifier(..)
  , ImplicitReconnect(..)
  , SendPortId(..)
  , Message
  , createMessage
  , sendPortProcessId
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)

-- | Named send to a process in the local registry (asynchronous)
nsend :: Serializable a => String -> a -> Process ()
nsend label msg = do
  proc <- ask
  let us = processId proc
  let msg' = wrapMessage msg
  -- see [note: tracing]
  liftIO $ traceEvent (localEventBus (processNode proc))
                      (MxSentToName label us msg')
  sendCtrlMsg Nothing (NamedSend label msg')

-- | Named send to a process in a remote registry (asynchronous)
nsendRemote :: Serializable a => NodeId -> String -> a -> Process ()
nsendRemote nid label msg = do
  proc <- ask
  let us = processId proc
  let node = processNode proc
  if localNodeId node == nid
    then nsend label msg
    else
      let lbl = label ++ "@" ++ show nid in do
        -- see [note: tracing] NB: this is a remote call to another NC...
        liftIO $ traceEvent (localEventBus node)
                            (MxSentToName lbl us (wrapMessage msg))
        sendCtrlMsg (Just nid) (NamedSend label (createMessage msg))

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
send them msg = do
  proc <- ask
  let node     = localNodeId (processNode proc)
      destNode = (processNodeId them)
      us       = (processId proc)
      msg'     = wrapMessage msg in do
    -- see [note: tracing]
    liftIO $ traceEvent (localEventBus (processNode proc))
                        (MxSent them us msg')
    if destNode == node
      then sendCtrlMsg Nothing $ LocalSend them msg'
      else liftIO $ sendMessage (processNode proc)
                                (ProcessIdentifier (processId proc))
                                (ProcessIdentifier them)
                                NoImplicitReconnect
                                msg

-- | Send a message unreliably.
--
-- Unlike 'send', this function is insensitive to 'reconnect'. It will
-- try to send the message regardless of the history of connection failures
-- between the nodes.
--
-- Message passing with 'usend' is ordered for a given sender and receiver
-- if the messages arrive at all.
--
usend :: Serializable a => ProcessId -> a -> Process ()
usend them msg = do
    proc <- ask
    let there = processNodeId them
    let (us, node) = (processId proc, processNode proc)
    let msg' = wrapMessage msg
    -- see [note: tracing]
    liftIO $ traceEvent (localEventBus node) (MxSent them us msg')
    if localNodeId (processNode proc) == there
      then sendCtrlMsg Nothing $ LocalSend them msg'
      else sendCtrlMsg (Just there) $ UnreliableSend (processLocalId them)
                                                     (createMessage msg)

-- [note: tracing]
-- Note that tracing writes to the local node's control channel, and this
-- module explicitly specifies to its clients that it does unsafe message
-- encoding. The same is true for the messages it puts onto the Management
-- event bus, however we do *not* want unevaluated thunks hitting the event
-- bus control thread. Hence the word /Unsafe/ in this module's name!
--

-- | Send a message on a typed channel
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan (SendPort cid) msg = do
  proc <- ask
  let node = processNode proc
      pid  = processId proc
      us   = localNodeId node
      them = processNodeId (sendPortProcessId cid)
      msg' = wrapMessage msg in do
  liftIO $ traceEvent (localEventBus node) (MxSentToPort pid cid msg')
  if them == us
    then unsafeSendChanLocal cid msg' -- NB: we wrap to P.Message !!!
    else liftIO $ sendBinary node
                             (ProcessIdentifier pid)
                             (SendPortIdentifier cid)
                             NoImplicitReconnect
                             msg
  where
    unsafeSendChanLocal :: SendPortId -> Message -> Process ()
    unsafeSendChanLocal p m = sendCtrlMsg Nothing $ LocalPortSend p m

-- | Create an unencoded @Message@ for any @Serializable@ type.
wrapMessage :: Serializable a => a -> Message
wrapMessage = unsafeCreateUnencodedMessage
