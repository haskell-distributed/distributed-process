{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

module Control.Distributed.Platform.Timer 
  (
    TimerRef
  , Tick(Tick)
  , milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
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
import Control.Distributed.Platform.Internal.Types
import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)
import Prelude hiding (init)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | An opaque reference to a timer.
type TimerRef = ProcessId

-- | cancellation message sent to timers
data TimerConfig = Reset | Cancel
    deriving (Typeable, Show)
$(derive makeBinary ''TimerConfig)

-- | Represents a 'tick' event that timers can generate
data Tick = Tick
    deriving (Typeable, Eq)
$(derive makeBinary ''Tick)

-- | Private data type used to guarantee that 'sleep' blocks on receive.
data SleepingPill = SleepingPill
    deriving (Typeable)
$(derive makeBinary ''SleepingPill)

-- time interval/unit handling

-- | converts the supplied @TimeInterval@ to milliseconds
intervalToMs :: TimeInterval -> Int
intervalToMs (TimeInterval u v) = timeToMs u v

-- | given a number, produces a @TimeInterval@ of milliseconds
milliseconds :: Int -> TimeInterval
milliseconds = TimeInterval Millis

-- | given a number, produces a @TimeInterval@ of seconds
seconds :: Int -> TimeInterval
seconds = TimeInterval Seconds

-- | given a number, produces a @TimeInterval@ of minutes
minutes :: Int -> TimeInterval
minutes = TimeInterval Minutes

-- | given a number, produces a @TimeInterval@ of hours
hours :: Int -> TimeInterval
hours = TimeInterval Hours

-- TODO: timeToMs is not exactly efficient and we need to scale it up to
--       deal with days, months, years, etc

-- | converts the supplied @TimeUnit@ to milliseconds
timeToMs :: TimeUnit -> Int -> Int
timeToMs Millis  ms   = ms
timeToMs Seconds sec  = sec * 1000
timeToMs Minutes mins = (mins * 60) * 1000
timeToMs Hours   hrs  = ((hrs * 60) * 60) * 1000

-- process implementations

-- | Blocks the calling Process for the specified TimeInterval. Note that this
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

-- | Starts a timer which sends the supplied message to the destination process
-- after the specified time interval. The message is sent only once, after
-- which the timer exits normally.
sendAfter :: (Serializable a) => TimeInterval -> ProcessId -> a -> Process TimerRef
sendAfter t pid msg = runAfter t (mkSender pid msg)

-- | Runs the supplied process action(s) after `t' has elapsed 
runAfter :: TimeInterval -> Process () -> Process TimerRef
runAfter t p = spawnLocal $ runTimer t p True   

-- | Starts a timer that repeatedly sends the supplied message to the destination
-- process each time the specified time interval elapses. To stop messages from
-- being sent in future, cancelTimer can be called.
startTimer :: (Serializable a) => TimeInterval -> ProcessId -> a -> Process TimerRef
startTimer t pid msg = periodically t (mkSender pid msg)

-- | runs the supplied process action(s) repeatedly at intervals of `t'
periodically :: TimeInterval -> Process () -> Process TimerRef
periodically t p = spawnLocal $ runTimer t p False

-- | Resets a running timer. Note: Cancelling a timer does not guarantee that
-- a timer's messages are prevented from being delivered to the target process.
-- Also note that resetting an ongoing timer (started using the `startTimer' or
-- `periodically' functions) will only cause the current elapsed period to time
-- out, after which the timer will continue running. To stop a long-running
-- timer, you should use `cancelTimer' instead.
resetTimer :: TimerRef -> Process ()
resetTimer = (flip send) Reset

cancelTimer :: TimerRef -> Process ()
cancelTimer = (flip send) Cancel

-- | Cancels a running timer and flushes any viable timer messages from the
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

-- | Sets up a timer that sends `Tick' repeatedly at intervals of `t'
ticker :: TimeInterval -> ProcessId -> Process TimerRef
ticker t pid = startTimer t pid Tick

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- Runs the timer process
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

-- Create a 'sender' action for dispatching `msg' to `pid'
mkSender :: (Serializable a) => ProcessId -> a -> Process ()
mkSender pid msg = do
  -- say "sending\n"
  send pid msg
