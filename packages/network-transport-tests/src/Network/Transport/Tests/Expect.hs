-- | Small assertion helpers that produce informative error messages in place
-- of the bare pattern-match failures that used to live all over the test
-- suite.
--
-- These helpers fail via 'ioError' / 'userError', so they compose cleanly with
-- the 'Network.Transport.Tests.Traced' machinery: the resulting exception is
-- still wrapped with a trace of the previous bound value.
module Network.Transport.Tests.Expect
  ( -- * Either
    expectRight
  , expectLeft
  , expectTransportError
    -- * Event
  , expectConnectionOpened
  , expectConnectionClosed
  , expectReceived
  , expectReceivedMulticast
  , expectEndPointClosed
  , expectErrorEvent
    -- * Generic
  , expectEq
  , expectTrue
  ) where

import Data.ByteString (ByteString)
import GHC.Stack (HasCallStack, callStack, popCallStack, prettyCallStack)
import Network.Transport
  ( ConnectionId
  , EndPointAddress
  , Event (ConnectionClosed, ConnectionOpened, EndPointClosed, ErrorEvent, Received, ReceivedMulticast)
  , EventErrorCode
  , MulticastAddress
  , Reliability
  , TransportError (TransportError)
  )

-- | Fail in 'IO' with a descriptive message and a call stack pointing at the
-- caller of the 'expect*' helper, not at 'failWith' itself.
--
-- This is the single source of truth for the \"hide our own frame, blame the
-- test\" convention: new @expect*@ helpers only need a @HasCallStack@
-- constraint and a plain call to 'failWith' — they do not need to wrap
-- anything in 'GHC.Stack.withFrozenCallStack'. 'failWith' pops its own frame
-- (always the top of the stack, since the @expect*@ helpers are its only
-- callers) before rendering the stack.
--
-- Implemented via 'userError' so the resulting 'IOError' is indistinguishable
-- from what a pattern-match failure would produce, keeping the behaviour of
-- 'Network.Transport.Tests.Traced' intact (it wraps these into 'TracedException'
-- with the previous bound value).
failWith :: HasCallStack => String -> IO a
failWith msg =
  ioError . userError $ msg ++ "\n" ++ prettyCallStack (popCallStack callStack)

-- | Expect @Right@; fail with a diagnostic containing the 'Left' value otherwise.
expectRight :: (HasCallStack, Show e) => String -> Either e a -> IO a
expectRight _       (Right x)  = return x
expectRight context (Left err) =
  failWith $ context ++ ": expected Right, got Left " ++ show err

-- | Expect @Left@; fail with a diagnostic containing the 'Right' value otherwise.
expectLeft :: (HasCallStack, Show a) => String -> Either e a -> IO e
expectLeft _       (Left e)  = return e
expectLeft context (Right x) =
  failWith $ context ++ ": expected Left, got Right " ++ show x

-- | Expect a particular 'TransportError' error code.
--
-- The human-readable string of the 'TransportError' is intentionally ignored
-- (matching the existing @Eq@ instance on 'TransportError').
--
-- The success value is not 'Show'n on a @Right@ result because types like
-- 'Network.Transport.Connection' have no 'Show' instance.
expectTransportError
  :: (HasCallStack, Eq code, Show code)
  => String
  -> code
  -> Either (TransportError code) a
  -> IO ()
expectTransportError context expected (Left (TransportError actual _))
  | expected == actual = return ()
  | otherwise =
      failWith $ context ++ ": expected TransportError " ++ show expected
              ++ ", got TransportError " ++ show actual
expectTransportError context expected (Right _) =
  failWith $ context ++ ": expected Left (TransportError " ++ show expected
          ++ " _), got Right value"

-- | Expect the 'Event' to be a 'ConnectionOpened' and return its fields.
expectConnectionOpened
  :: HasCallStack => Event -> IO (ConnectionId, Reliability, EndPointAddress)
expectConnectionOpened (ConnectionOpened cid rel addr) = return (cid, rel, addr)
expectConnectionOpened ev =
  failWith $ "expected ConnectionOpened, got: " ++ show ev

-- | Expect the 'Event' to be a 'ConnectionClosed' and return its connection id.
expectConnectionClosed :: HasCallStack => Event -> IO ConnectionId
expectConnectionClosed (ConnectionClosed cid) = return cid
expectConnectionClosed ev =
  failWith $ "expected ConnectionClosed, got: " ++ show ev

-- | Expect the 'Event' to be a 'Received' and return its fields.
expectReceived :: HasCallStack => Event -> IO (ConnectionId, [ByteString])
expectReceived (Received cid payload) = return (cid, payload)
expectReceived ev =
  failWith $ "expected Received, got: " ++ show ev

-- | Expect the 'Event' to be a 'ReceivedMulticast' and return its fields.
expectReceivedMulticast :: HasCallStack => Event -> IO (MulticastAddress, [ByteString])
expectReceivedMulticast (ReceivedMulticast addr payload) = return (addr, payload)
expectReceivedMulticast ev =
  failWith $ "expected ReceivedMulticast, got: " ++ show ev

-- | Expect the 'Event' to be 'EndPointClosed'.
expectEndPointClosed :: HasCallStack => Event -> IO ()
expectEndPointClosed EndPointClosed = return ()
expectEndPointClosed ev =
  failWith $ "expected EndPointClosed, got: " ++ show ev

-- | Expect the 'Event' to be an 'ErrorEvent' and return its transport error.
expectErrorEvent :: HasCallStack => Event -> IO (TransportError EventErrorCode)
expectErrorEvent (ErrorEvent err) = return err
expectErrorEvent ev =
  failWith $ "expected ErrorEvent, got: " ++ show ev

-- | Assert that two values are equal; fail with a diagnostic showing both
-- values otherwise.
expectEq :: (HasCallStack, Eq a, Show a) => String -> a -> a -> IO ()
expectEq what expected actual
  | expected == actual = return ()
  | otherwise =
      failWith $ what ++ ": expected " ++ show expected
              ++ ", got " ++ show actual

-- | Assert that a 'Bool' is 'True'; fail with a message otherwise.
expectTrue :: HasCallStack => String -> Bool -> IO ()
expectTrue _       True  = return ()
expectTrue message False = failWith $ "expectTrue failed: " ++ message
