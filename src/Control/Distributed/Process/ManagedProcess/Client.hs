{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.ManagedProcess.Client
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Client Portion of the /Managed Process/ API.
-----------------------------------------------------------------------------

module Control.Distributed.Process.ManagedProcess.Client
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
  , callSTM
  ) where

import Control.Concurrent.STM (atomically, STM)
import Control.Distributed.Process hiding (call, finally)
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Async hiding (check)
import Control.Distributed.Process.ManagedProcess.Internal.Types
import qualified Control.Distributed.Process.ManagedProcess.Internal.Types as T
import Control.Distributed.Process.Extras.Internal.Types (resolveOrDie)
import Control.Distributed.Process.Extras hiding (monitor, sendChan)
import Control.Distributed.Process.Extras.Time
import Control.Monad.Catch (finally)
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
-- if the operation fails. If the calling process dies (that is, forces itself
-- to exit such that an exit signal arises with @ExitOther String@) then
-- evaluation will return @Left exitReason@ and the explanation will be
-- stashed away as @(ExitOther String)@.
--
-- __NOTE: this function does not catch exceptions!__
--
-- The /safety/ of the name, comes from carefully handling situations in which
-- the server dies while we're waiting for a reply. Notably, exit signals from
-- other processes, kill signals, and both synchronous and asynchronous
-- exceptions can still terminate the caller abruptly. To avoid this consider
-- masking or evaluating within your own exception handling code.
--
safeCall :: forall s a b . (Addressable s, Serializable a, Serializable b)
                 => s -> a -> Process (Either ExitReason b)
safeCall s m = do
  us <- getSelfPid
  (fmap fromJust (initCall s m >>= waitResponse Nothing) :: Process (Either ExitReason b))
    `catchesExit` [(\pid msg -> handleMessageIf msg (weFailed pid us)
                                                    (return . Left))]

  where

    weFailed a b (ExitOther _) = a == b
    weFailed _ _ _             = False

-- | Version of 'safeCall' that returns 'Nothing' if the operation fails. If
-- you need information about *why* a call has failed then you should use
-- 'safeCall' or combine @catchExit@ and @call@ instead.
--
-- __NOTE: this function does not catch exceptions!__
--
-- In fact, this API handles fewer exceptions than it's relative, "safeCall".
-- Notably, exit signals, kill signals, and both synchronous and asynchronous
-- exceptions can still terminate the caller abruptly. To avoid this consider
-- masking or evaluating within your own exception handling code (as mentioned
-- above).
--
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
flushPendingCalls d proc =
  receiveTimeout (asTimeout d) [
      match (\(CallResponse (m :: b) _) -> proc m)
    ]

-- | Invokes 'call' /out of band/, and returns an /async handle/.
--
callAsync :: forall s a b . (Addressable s, Serializable a, Serializable b)
          => s -> a -> Process (Async b)
callAsync server msg = async $ task $ call server msg

-- | Sends a /cast/ message to the server identified by @server@. The server
-- will not send a response. Like Cloud Haskell's 'send' primitive, cast is
-- fully asynchronous and /never fails/ - therefore 'cast'ing to a non-existent
-- (e.g., dead) server process will not generate an error.
--
cast :: forall a m . (Addressable a, Serializable m)
                 => a -> m -> Process ()
cast server msg = sendTo server (CastMessage msg :: T.Message m ())

-- | Sends a /channel/ message to the server and returns a @ReceivePort@ on
-- which the reponse can be delivered, if the server so chooses (i.e., the
-- might ignore the request or crash).
callChan :: forall s a b . (Addressable s, Serializable a, Serializable b)
         => s -> a -> Process (ReceivePort b)
callChan server msg = do
  (sp, rp) <- newChan
  sendTo server (ChanMessage msg sp :: T.Message a b)
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

-- | Manages an rpc-style interaction with a server process, using @STM@ actions
-- to read/write data. The server process is monitored for the duration of the
-- /call/. The stm write expression is passed the input, and the read expression
-- is evaluated and the result given as @Right b@ or @Left ExitReason@ if a
-- monitor signal is detected whilst waiting.
--
-- Note that the caller will exit (with @ExitOther String@) if the server
-- address is un-resolvable.
--
-- A note about scheduling and timing guarantees (or lack thereof): It is not
-- possibly to guarantee the contents of @ExitReason@ in cases where this API
-- fails due to server exits/crashes. We establish a monitor prior to evaluating
-- the stm writer action, however @monitor@ is asychronous and we've no way to
-- know whether or not the scheduler will allow monitor establishment to proceed
-- first, or the stm transaction. As a result, assuming that your server process
-- can die/fail/exit on evaluating the read end of the STM write we perform here
-- (and we assume this is very likely, since we apply no safety rules and do not
-- even worry about serializing thunks passed from the client's thread), it is
-- just as likely that in the case of failure you will see a reason such as
-- @ExitOther "DiedUnknownId"@ due to the server process crashing before the node
-- controller can establish a monitor.
--
-- As unpleasant as this is, there's little we can do about it without making
-- false assumptions about the runtime. Cloud Haskell's semantics guarantee us
-- only that we will see /some/ monitor signal in the event of a failure here.
-- To provide a more robust error handling, you can catch/trap failures in the
-- server process and return a wrapper reponse datum here instead. This will
-- /still/ be subject to the failure modes described above in cases where the
-- server process exits abnormally, but that will at least allow the caller to
-- differentiate between expected and exceptional failure conditions.
--
callSTM :: forall s a b . (Addressable s)
         => s
         -> (a -> STM ())
         -> STM b
         -> a
         -> Process (Either ExitReason b)
callSTM server writeAction readAction input = do
    -- NB: we must establish the monitor before writing, to ensure we have
    -- a valid ref such that server failure gets reported properly
    pid <- resolveOrDie server "callSTM: unresolveable address "
    mRef <- monitor pid

    liftIO $ atomically $ writeAction input

    finally (receiveWait [ matchRef mRef
                         , matchSTM readAction (return . Right)
                         ])
            (unmonitor mRef)

  where
    matchRef :: MonitorRef -> Match (Either ExitReason b)
    matchRef r = matchIf (\(ProcessMonitorNotification r' _ _) -> r == r')
                         (\(ProcessMonitorNotification _ _ d) ->
                            return (Left (ExitOther (show d))))
