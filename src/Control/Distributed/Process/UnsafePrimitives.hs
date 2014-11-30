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
-- behaviour of your application. You have been warned!
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
  , wrapMessage
  ) where

import Control.Distributed.Process.Internal.Messaging
  ( sendMessage
  , sendBinary
  , sendCtrlMsg
  )

import Control.Distributed.Process.Internal.Types
  ( ProcessId(..)
  , LocalNode(..)
  , LocalProcess(..)
  , Process(..)
  , SendPort(..)
  , ProcessSignal(..)
  , Identifier(..)
  , ImplicitReconnect(..)
  , SendPortId(..)
  , Message
  , sendPortProcessId
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Serializable (Serializable)

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)

-- | Named send to a process in the local registry (asynchronous)
nsend :: Serializable a => String -> a -> Process ()
nsend label msg =
  sendCtrlMsg Nothing (NamedSend label (unsafeCreateUnencodedMessage msg))

-- | Send a message
send :: Serializable a => ProcessId -> a -> Process ()
send them msg = do
  proc <- ask
  let node     = localNodeId (processNode proc)
      destNode = (processNodeId them) in do
  case destNode == node of
    True  -> unsafeSendLocal them msg
    False -> liftIO $ sendMessage (processNode proc)
                                  (ProcessIdentifier (processId proc))
                                  (ProcessIdentifier them)
                                  NoImplicitReconnect
                                  msg
  where
    unsafeSendLocal :: (Serializable a) => ProcessId -> a -> Process ()
    unsafeSendLocal pid msg' =
      sendCtrlMsg Nothing $ LocalSend pid (unsafeCreateUnencodedMessage msg')

-- | Send a message on a typed channel
sendChan :: Serializable a => SendPort a -> a -> Process ()
sendChan (SendPort cid) msg = do
  proc <- ask
  let node     = localNodeId (processNode proc)
      destNode = processNodeId (sendPortProcessId cid) in do
  case destNode == node of
    True  -> unsafeSendChanLocal cid msg
    False -> do
      liftIO $ sendBinary (processNode proc)
                          (ProcessIdentifier (processId proc))
                          (SendPortIdentifier cid)
                          NoImplicitReconnect
                          msg
  where
    unsafeSendChanLocal :: (Serializable a) => SendPortId -> a -> Process ()
    unsafeSendChanLocal spId msg' =
      sendCtrlMsg Nothing $ LocalPortSend spId (unsafeCreateUnencodedMessage msg')

-- | Create an unencoded @Message@ for any @Serializable@ type.
wrapMessage :: Serializable a => a -> Message
wrapMessage = unsafeCreateUnencodedMessage
