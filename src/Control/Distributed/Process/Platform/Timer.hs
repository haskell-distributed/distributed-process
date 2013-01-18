{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Timer
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- Provides an API for running code or sending messages, either after some
-- initial delay or periodically, and for cancelling, re-setting and/or
-- flushing pending /timers/.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Timer
  (
    TimerRef
  , Tick(Tick)
  , sleep
  , sendAfter
  , runAfter
  , exitAfter
  , killAfter
  , startTimer
  , ticker
  , periodically
  , resetTimer
  , cancelTimer
  , flushTimer
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Time
import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)
import Prelude hiding (init)

-- | an opaque reference to a timer
type TimerRef = ProcessId

-- | cancellation message sent to timers
data TimerConfig = Reset | Cancel
    deriving (Typeable, Show)
$(derive makeBinary ''TimerConfig)

-- | represents a 'tick' event that timers can generate
data Tick = Tick
    deriving (Typeable, Eq)
$(derive makeBinary ''Tick)

data SleepingPill = SleepingPill
    deriving (Typeable)
$(derive makeBinary ''SleepingPill)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | blocks the calling Process for the specified TimeInterval. Note that this
-- function assumes that a blocking receive is the most efficient approach to
-- acheiving this, however the runtime semantics (particularly with regards
-- scheduling) should not differ from threadDelay in practise.
sleep :: TimeInterval -> Process ()
sleep t =
  let ms = asTimeout t in do
  -- liftIO $ putStrLn $ "sleeping for " ++ (show ms) ++ "micros"
  _ <- receiveTimeout ms [matchIf (\SleepingPill -> True)
                                  (\_ -> return ())]
  return ()

-- | starts a timer which sends the supplied message to the destination
-- process after the specified time interval.
sendAfter :: (Serializable a)
          => TimeInterval
          -> ProcessId
          -> a
          -> Process TimerRef
sendAfter t pid msg = runAfter t proc
  where proc = do { send pid msg }

-- | runs the supplied process action(s) after @t@ has elapsed
runAfter :: TimeInterval -> Process () -> Process TimerRef
runAfter t p = spawnLocal $ runTimer t p True

-- | calls @exit pid reason@ after @t@ has elapsed
exitAfter :: (Serializable a)
             => TimeInterval
             -> ProcessId
             -> a
             -> Process TimerRef
exitAfter delay pid reason = runAfter delay $ exit pid reason

-- | kills the specified process after @t@ has elapsed
killAfter :: TimeInterval -> ProcessId -> String -> Process TimerRef
killAfter delay pid why = runAfter delay $ kill pid why

-- | starts a timer that repeatedly sends the supplied message to the destination
-- process each time the specified time interval elapses. To stop messages from
-- being sent in future, 'cancelTimer' can be called.
startTimer :: (Serializable a)
           => TimeInterval
           -> ProcessId
           -> a
           -> Process TimerRef
startTimer t pid msg = periodically t (send pid msg)

-- | runs the supplied process action(s) repeatedly at intervals of @t@
periodically :: TimeInterval -> Process () -> Process TimerRef
periodically t p = spawnLocal $ runTimer t p False

-- | resets a running timer. Note: Cancelling a timer does not guarantee that
-- all its messages are prevented from being delivered to the target process.
-- Also note that resetting an ongoing timer (started using the 'startTimer' or
-- 'periodically' functions) will only cause the current elapsed period to time
-- out, after which the timer will continue running. To stop a long-running
-- timer permanently, you should use 'cancelTimer' instead.
resetTimer :: TimerRef -> Process ()
resetTimer = (flip send) Reset

-- | permanently cancels a timer
cancelTimer :: TimerRef -> Process ()
cancelTimer = (flip send) Cancel

-- | cancels a running timer and flushes any viable timer messages from the
-- process' message queue. This function should only be called by the process
-- expecting to receive the timer's messages!
flushTimer :: (Serializable a, Eq a) => TimerRef -> a -> Delay -> Process ()
flushTimer ref ignore t = do
    mRef <- monitor ref
    cancelTimer ref
    performFlush mRef t
    return ()
  where performFlush mRef Infinity    = receiveWait $ filters mRef
        performFlush mRef (Delay i) =
            receiveTimeout (asTimeout i) (filters mRef) >> return ()
        filters mRef = [
                matchIf (\x -> x == ignore)
                        (\_ -> return ())
              , matchIf (\(ProcessMonitorNotification mRef' _ _) -> mRef == mRef')
                        (\_ -> return ()) ]

-- | sets up a timer that sends 'Tick' repeatedly at intervals of @t@
ticker :: TimeInterval -> ProcessId -> Process TimerRef
ticker t pid = startTimer t pid Tick

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- runs the timer process
runTimer :: TimeInterval -> Process () -> Bool -> Process ()
runTimer t proc cancelOnReset = do
    cancel <- expectTimeout (asTimeout t)
    -- say $ "cancel = " ++ (show cancel) ++ "\n"
    case cancel of
        Nothing     -> runProc cancelOnReset
        Just Cancel -> return ()
        Just Reset  -> if cancelOnReset then return ()
                                        else runTimer t proc cancelOnReset
  where runProc True  = proc
        runProc False = proc >> runTimer t proc cancelOnReset
