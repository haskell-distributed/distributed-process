{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.ManagedProcess.Client
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Client Portion of the /Managed Process/ API.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.ManagedProcess.Client
  ( -- * API for client interactions with the process
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

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Async hiding (check)
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import qualified Control.Distributed.Process.Platform.ManagedProcess.Internal.Types as T
import Control.Distributed.Process.Platform.Internal.Primitives hiding (monitor)
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  , Shutdown(..)
  )
import Control.Distributed.Process.Platform.Time
import Data.Maybe (fromJust)

import Prelude hiding (init)

-- | Send a control message over a 'ControlPort'.
--
sendControlMessage :: Serializable m => ControlPort m -> m -> Process ()
sendControlMessage cp m = sendChan (unPort cp) (CastMessage m)

-- | Send a signal instructing the process to terminate. The /receive loop/ which
-- manages the process mailbox will prioritise @Shutdown@ signals higher than
-- any other incoming messages, but the server might be busy (i.e., still in the
-- process of excuting a handler) at the time of sending however, so the caller
-- should not make any assumptions about the timeliness with which the shutdown
-- signal will be handled. If responsiveness is important, a better approach
-- might be to send an /exit signal/ with 'Shutdown' as the reason. An exit
-- signal will interrupt any operation currently underway and force the running
-- process to clean up and terminate.
shutdown :: ProcessId -> Process ()
shutdown pid = cast pid Shutdown

-- | Make a synchronous call - will block until a reply is received.
-- The calling process will exit with 'ExitReason' if the calls fails.
call :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> Process b
call sid msg = initCall sid msg >>= waitResponse Nothing >>= decodeResult
  where decodeResult (Just (Right r))  = return r
        decodeResult (Just (Left err)) = die err
        decodeResult Nothing {- the impossible happened -} = terminate

-- | Safe version of 'call' that returns information about the error
-- if the operation fails. If an error occurs then the explanation will be
-- will be stashed away as @(ExitOther String)@.
safeCall :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> Process (Either ExitReason b)
safeCall s m = initCall s m >>= waitResponse Nothing >>= return . fromJust

-- | Version of 'safeCall' that returns 'Nothing' if the operation fails. If
-- you need information about *why* a call has failed then you should use
-- 'safeCall' or combine @catchExit@ and @call@ instead.
tryCall :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> Process (Maybe b)
tryCall s m = initCall s m >>= waitResponse Nothing >>= decodeResult
  where decodeResult (Just (Right r)) = return $ Just r
        decodeResult _                = return Nothing

-- | Make a synchronous call, but timeout and return @Nothing@ if a reply
-- is not received within the specified time interval.
--
-- If the result of the call is a failure (or the call was cancelled) then
-- the calling process will exit, with the 'ExitReason' given as the reason.
-- If the call times out however, the semantics on the server side are
-- undefined, i.e., the server may or may not successfully process the
-- request and may (or may not) send a response at a later time. From the
-- callers perspective, this is somewhat troublesome, since the call result
-- cannot be decoded directly. In this case, the 'flushPendingCalls' API /may/
-- be used to attempt to receive the message later on, however this makes
-- /no attempt whatsoever/ to guarantee /which/ call response will in fact
-- be returned to the caller. In those semantics are unsuited to your
-- application, you might choose to @exit@ or @die@ in case of a timeout,
-- or alternatively, use the 'callAsync' API and associated @waitTimeout@
-- function (in the /Async API/), which takes a re-usable handle on which
-- to wait (with timeouts) multiple times.
--
callTimeout :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> TimeInterval -> Process (Maybe b)
callTimeout s m d = initCall s m >>= waitResponse (Just d) >>= decodeResult
  where decodeResult :: (Serializable b)
               => Maybe (Either ExitReason b)
               -> Process (Maybe b)
        decodeResult Nothing               = return Nothing
        decodeResult (Just (Right result)) = return $ Just result
        decodeResult (Just (Left reason))  = die reason

flushPendingCalls :: forall b . (Serializable b)
                  => TimeInterval
                  -> (b -> Process b)
                  -> Process (Maybe b)
flushPendingCalls d proc = do
  receiveTimeout (asTimeout d) [
      match (\(CallResponse (m :: b) _) -> proc m)
    ]

-- | Invokes 'call' /out of band/, and returns an /async handle/.
--
-- See "Control.Distributed.Process.Platform.Async".
--
callAsync :: forall s a b . (Addressable s, Serializable a, Serializable b)
          => s -> a -> Process (Async b)
callAsync server msg = async $ call server msg

-- | Sends a /cast/ message to the server identified by @server@. The server
-- will not send a response. Like Cloud Haskell's 'send' primitive, cast is
-- fully asynchronous and /never fails/ - therefore 'cast'ing to a non-existent
-- (e.g., dead) server process will not generate an error.
--
cast :: forall a m . (Addressable a, Serializable m)
                 => a -> m -> Process ()
cast server msg = sendTo server ((CastMessage msg) :: T.Message m ())

-- | Sends a /channel/ message to the server and returns a @ReceivePort@ on
-- which the reponse can be delivered, if the server so chooses (i.e., the
-- might ignore the request or crash).
callChan :: forall s a b . (Addressable s, Serializable a, Serializable b)
         => s -> a -> Process (ReceivePort b)
callChan server msg = do
  (sp, rp) <- newChan
  sendTo server ((ChanMessage msg sp) :: T.Message a b)
  return rp

-- | A synchronous version of 'callChan'.
syncCallChan :: forall s a b . (Addressable s, Serializable a, Serializable b)
         => s -> a -> Process b
syncCallChan server msg = do
  r <- syncSafeCallChan server msg
  case r of
    Left e   -> die e
    Right r' -> return r'

-- | A safe version of 'syncCallChan', which returns @Left ExitReason@ if the
-- call fails.
syncSafeCallChan :: forall s a b . (Addressable s, Serializable a, Serializable b)
            => s -> a -> Process (Either ExitReason b)
syncSafeCallChan server msg = do
  rp <- callChan server msg
  awaitResponse server [ matchChan rp (return . Right) ]

