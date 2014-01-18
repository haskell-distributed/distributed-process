-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.UnsafePrimitives
-- Copyright   :  (c) Tim Watson 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- [Unsafe Messaging Primitives Using NFData]
--
-- This module mirrors "Control.Distributed.Process.UnsafePrimitives", but
-- attempts to provide a bit more safety by forcing evaluation before sending.
-- This is handled using @NFData@, by means of the @NFSerializable@ type class.
--
-- Note that we /still/ cannot guarantee that both the @NFData@ and @Binary@
-- instances will evaluate your data the same way, therefore these primitives
-- still have certain risks and potential side effects. Use with caution.
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Platform.UnsafePrimitives
  ( send
  , nsend
  , sendToAddr
  , sendChan
  , wrapMessage
  ) where

import Control.DeepSeq (($!!))
import Control.Distributed.Process
  ( Process
  , ProcessId
  , SendPort
  , Message
  )
import Control.Distributed.Process.Platform.Internal.Types
  ( NFSerializable
  , Addressable
  , Resolvable(..)
  )
import qualified Control.Distributed.Process.UnsafePrimitives as Unsafe

send :: NFSerializable m => ProcessId -> m -> Process ()
send pid msg = Unsafe.send pid $!! msg

nsend :: NFSerializable a => String -> a -> Process ()
nsend name msg = Unsafe.nsend name $!! msg

sendToAddr :: (Addressable a, NFSerializable m) => a -> m -> Process ()
sendToAddr addr msg = do
  mPid <- resolve addr
  case mPid of
    Nothing -> return ()
    Just p  -> send p msg

sendChan :: (NFSerializable m) => SendPort m -> m -> Process ()
sendChan port msg = Unsafe.sendChan port $!! msg

-- | Create an unencoded @Message@ for any @Serializable@ type.
wrapMessage :: NFSerializable a => a -> Message
wrapMessage msg = Unsafe.wrapMessage $!! msg

