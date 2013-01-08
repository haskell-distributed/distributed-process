{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module Control.Distributed.Process.Platform.Timer 
  (
    TimerRef
  , Tick(Tick)
  , sleep
  , sendAfter
  , runAfter
  , startTimer
  , ticker
  , periodically
  , resetTimer
  , cancelTimer
  , flushTimer
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Platform.Internal.Types
import Control.Distributed.Process.Platform
import Data.Binary
import Data.DeriveTH
import Data.Typeable                               (Typeable)
import Prelude                                     hiding (init)

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
-- acheiving this, so expect the runtime semantics (particularly with regards
-- scheduling) to differ from threadDelay and/or operating system specific 
-- functions that offer the same results.
sleep :: TimeInterval -> Process ()
sleep t = do
  let ms = intervalToMs t
  _ <- receiveTimeout ms [matchIf (\SleepingPill -> True)
                                  (\_ -> return ())]
  return ()

-- | starts a timer which sends the supplied message to the destination process
-- after the specified time interval.
sendAfter :: (Serializable a) => TimeInterval -> ProcessId -> a -> Process TimerRef
sendAfter t pid msg = runAfter t (mkSender pid msg)

-- | runs the supplied process action(s) after `t' has elapsed 
runAfter :: TimeInterval -> Process () -> Process TimerRef
runAfter t p = spawnLocal $ runTimer t p True   

-- | starts a timer that repeatedly sends the supplied message to the destination
-- process each time the specified time interval elapses. To stop messages from
-- being sent in future, cancelTimer can be called.
startTimer :: (Serializable a) => TimeInterval -> ProcessId -> a -> Process TimerRef
startTimer t pid msg = periodically t (mkSender pid msg)

-- | runs the supplied process action(s) repeatedly at intervals of `t'
periodically :: TimeInterval -> Process () -> Process TimerRef
periodically t p = spawnLocal $ runTimer t p False

-- | resets a running timer. Note: Cancelling a timer does not guarantee that
-- a timer's messages are prevented from being delivered to the target process.
-- Also note that resetting an ongoing timer (started using the `startTimer' or
-- `periodically' functions) will only cause the current elapsed period to time
-- out, after which the timer will continue running. To stop a long-running
-- timer, you should use `cancelTimer' instead.
resetTimer :: TimerRef -> Process ()
resetTimer = (flip send) Reset

cancelTimer :: TimerRef -> Process ()
cancelTimer = (flip send) Cancel

-- | cancels a running timer and flushes any viable timer messages from the
-- process' message queue. This function should only be called by the process
-- expecting to receive the timer's messages!
flushTimer :: (Serializable a, Eq a) => TimerRef -> a -> Timeout -> Process () 
flushTimer ref ignore t = do
    mRef <- monitor ref
    cancelTimer ref
    -- TODO: monitor the timer ref (pid) and ensure it's gone before finishing
    performFlush mRef t
    return ()
  where performFlush mRef Infinity    = receiveWait $ filters mRef
        performFlush mRef (Timeout i) =
            receiveTimeout (intervalToMs i) (filters mRef) >> return ()
        filters mRef = [
                matchIf (\x -> x == ignore)
                        (\_ -> return ())
              , matchIf (\(ProcessMonitorNotification mRef' _ _) -> mRef == mRef')
                        (\_ -> return ()) ]

-- | sets up a timer that sends `Tick' repeatedly at intervals of `t'
ticker :: TimeInterval -> ProcessId -> Process TimerRef
ticker t pid = startTimer t pid Tick

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- runs the timer process
runTimer :: TimeInterval -> Process () -> Bool -> Process ()
runTimer t proc cancelOnReset = do
    cancel <- expectTimeout (intervalToMs t)
    -- say $ "cancel = " ++ (show cancel) ++ "\n"
    case cancel of
        Nothing     -> runProc cancelOnReset
        Just Cancel -> return ()
        Just Reset  -> if cancelOnReset then return ()
                                        else runTimer t proc cancelOnReset
  where runProc True  = proc
        runProc False = proc >> runTimer t proc cancelOnReset

-- create a 'sender' action for dispatching `msg' to `pid'
mkSender :: (Serializable a) => ProcessId -> a -> Process ()
mkSender pid msg = do
  -- say "sending\n"
  send pid msg
