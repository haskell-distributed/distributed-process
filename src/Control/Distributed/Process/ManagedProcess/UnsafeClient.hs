{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.ManagedProcess.UnsafeClient
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- Unsafe variant of the /Managed Process Client API/. This module implements
-- the client portion of a Managed Process using the unsafe variants of cloud
-- haskell's messaging primitives. It relies on the Platform implementation of
-- @UnsafePrimitives@, which forces evaluation for types that provide an
-- @NFData@ instance. Direct use of the underlying unsafe primitives (from
-- the distributed-process library) without @NFData@ instances is unsupported.
--
-- IMPORTANT NOTE: As per the platform documentation, it is not possible to
-- /guarantee/ that an @NFData@ instance will force evaluation in the same way
-- that a @Binary@ instance would (when encoding to a byte string). Please read
-- the unsafe primitives documentation carefully and make sure you know what
-- you're doing. You have been warned.
--
-- See "Control.Distributed.Process.Platform".
-- See "Control.Distributed.Process.Platform.UnsafePrimitives".
-- See "Control.Distributed.Process.UnsafePrimitives".
-----------------------------------------------------------------------------

-- TODO: This module is basically cut+paste duplicaton of the /safe/ Client - fix
-- Caveats... we've got to support two different type constraints, somehow, so
-- that the correct implementation gets used depending on whether or not we're
-- passing NFData or just Binary instances...

module Control.Distributed.Process.Platform.ManagedProcess.UnsafeClient
  ( -- * Unsafe variants of the Client API
    sendControlMessage
  , shutdown
  , call
  , safeCall
  , tryCall
  , callTimeout
  , flushPendingCalls
  , callAsync
  , cast
  , callChan
  , syncCallChan
  , syncSafeCallChan
  ) where

import Control.Distributed.Process
  ( Process
  , ProcessId
  , ReceivePort
  , newChan
  , matchChan
  , match
  , die
  , terminate
  , receiveTimeout
  , unsafeSendChan
  )
import Control.Distributed.Process.Platform.Async
  ( Async
  , async
  )
import Control.Distributed.Process.Platform.Internal.Primitives
  ( awaitResponse
  )
import Control.Distributed.Process.Platform.Internal.Types
  ( Addressable
  , Routable(..)
  , NFSerializable
  , ExitReason
  , Shutdown(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
  ( Message(CastMessage, ChanMessage)
  , CallResponse(..)
  , ControlPort(..)
  , unsafeInitCall
  , waitResponse
  )
import Control.Distributed.Process.Platform.Time
  ( TimeInterval
  , asTimeout
  )
import Control.Distributed.Process.Serializable hiding (SerializableDict)
import Data.Maybe (fromJust)

-- | Send a control message over a 'ControlPort'. This version of
-- @shutdown@ uses /unsafe primitives/.
--
sendControlMessage :: Serializable m => ControlPort m -> m -> Process ()
sendControlMessage cp m = unsafeSendChan (unPort cp) (CastMessage m)

-- | Send a signal instructing the process to terminate. This version of
-- @shutdown@ uses /unsafe primitives/.
shutdown :: ProcessId -> Process ()
shutdown pid = cast pid Shutdown

-- | Make a synchronous call - uses /unsafe primitives/.
call :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
                 => s -> a -> Process b
call sid msg = unsafeInitCall sid msg >>= waitResponse Nothing >>= decodeResult
  where decodeResult (Just (Right r))  = return r
        decodeResult (Just (Left err)) = die err
        decodeResult Nothing {- the impossible happened -} = terminate

-- | Safe version of 'call' that returns information about the error
-- if the operation fails - uses /unsafe primitives/.
safeCall :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
                 => s -> a -> Process (Either ExitReason b)
safeCall s m = unsafeInitCall s m >>= waitResponse Nothing >>= return . fromJust

-- | Version of 'safeCall' that returns 'Nothing' if the operation fails.
--  Uses /unsafe primitives/.
tryCall :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
                 => s -> a -> Process (Maybe b)
tryCall s m = unsafeInitCall s m >>= waitResponse Nothing >>= decodeResult
  where decodeResult (Just (Right r)) = return $ Just r
        decodeResult _                = return Nothing

-- | Make a synchronous call, but timeout and return @Nothing@ if a reply
-- is not received within the specified time interval  - uses /unsafe primitives/.
--
callTimeout :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
                 => s -> a -> TimeInterval -> Process (Maybe b)
callTimeout s m d = unsafeInitCall s m >>= waitResponse (Just d) >>= decodeResult
  where decodeResult :: (NFSerializable b)
               => Maybe (Either ExitReason b)
               -> Process (Maybe b)
        decodeResult Nothing               = return Nothing
        decodeResult (Just (Right result)) = return $ Just result
        decodeResult (Just (Left reason))  = die reason

flushPendingCalls :: forall b . (NFSerializable b)
                  => TimeInterval
                  -> (b -> Process b)
                  -> Process (Maybe b)
flushPendingCalls d proc = do
  receiveTimeout (asTimeout d) [
      match (\(CallResponse (m :: b) _) -> proc m)
    ]

-- | Invokes 'call' /out of band/, and returns an "async handle."
-- Uses /unsafe primitives/.
--
callAsync :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
          => s -> a -> Process (Async b)
callAsync server msg = async $ call server msg

-- | Sends a /cast/ message to the server identified by @server@ - uses /unsafe primitives/.
--
cast :: forall a m . (Addressable a, NFSerializable m)
                 => a -> m -> Process ()
cast server msg = unsafeSendTo server ((CastMessage msg) :: Message m ())

-- | Sends a /channel/ message to the server and returns a @ReceivePort@ - uses /unsafe primitives/.
callChan :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
         => s -> a -> Process (ReceivePort b)
callChan server msg = do
  (sp, rp) <- newChan
  unsafeSendTo server ((ChanMessage msg sp) :: Message a b)
  return rp

syncCallChan :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
         => s -> a -> Process b
syncCallChan server msg = do
  r <- syncSafeCallChan server msg
  case r of
    Left e   -> die e
    Right r' -> return r'

syncSafeCallChan :: forall s a b . (Addressable s, NFSerializable a, NFSerializable b)
            => s -> a -> Process (Either ExitReason b)
syncSafeCallChan server msg = do
  rp <- callChan server msg
  awaitResponse server [ matchChan rp (return . Right) ]

