{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Time
-- Copyright   :  (c) Tim Watson, Jeff Epstein, Alan Zimmerman
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides facilities for working with time delays and timeouts.
-- The type 'Timeout' and the 'timeout' family of functions provide mechanisms
-- for working with @threadDelay@-like behaviour that operates on microsecond
-- values.
--
-- The 'TimeInterval' and 'TimeUnit' related functions provide an abstraction
-- for working with various time intervals, whilst the 'Delay' type provides a
-- corrolary to 'timeout' that works with these.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Time
  ( -- * Time interval handling
    microSeconds
  , milliSeconds
  , seconds
  , minutes
  , hours
  , asTimeout
  , after
  , within
  , timeToMicros
  , TimeInterval
  , TimeUnit(..)
  , Delay(..)

  -- * Conversion To/From NominalDiffTime
  , timeIntervalToDiffTime
  , diffTimeToTimeInterval
  , diffTimeToDelay
  , delayToDiffTime
  , microsecondsToNominalDiffTime

    -- * (Legacy) Timeout Handling
  , Timeout
  , TimeoutNotification(..)
  , timeout
  , infiniteWait
  , noWait
  ) where

import Control.Concurrent (threadDelay)
import Control.DeepSeq (NFData)
import Control.Distributed.Process
import Control.Distributed.Process.Platform.Internal.Types
import Control.Monad (void)
import Data.Binary
import Data.Ratio ((%))
import Data.Time.Clock
import Data.Typeable (Typeable)

import GHC.Generics

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Defines the time unit for a Timeout value
data TimeUnit = Days | Hours | Minutes | Seconds | Millis | Micros
    deriving (Typeable, Generic, Eq, Show)

instance Binary TimeUnit where
instance NFData TimeUnit where

-- | A time interval.
data TimeInterval = TimeInterval TimeUnit Int
    deriving (Typeable, Generic, Eq, Show)

instance Binary TimeInterval where
instance NFData TimeInterval where

-- | Represents either a delay of 'TimeInterval', an infinite wait or no delay
-- (i.e., non-blocking).
data Delay = Delay TimeInterval | Infinity | NoDelay
    deriving (Typeable, Generic, Eq, Show)

instance Binary Delay where
instance NFData Delay where

-- | Represents a /timeout/ in terms of microseconds, where 'Nothing' stands for
-- infinity and @Just 0@, no-delay.
type Timeout = Maybe Int

-- | Send to a process when a timeout expires.
data TimeoutNotification = TimeoutNotification Tag
       deriving (Typeable)

instance Binary TimeoutNotification where
  get = fmap TimeoutNotification $ get
  put (TimeoutNotification n) = put n

-- time interval/unit handling

-- | converts the supplied @TimeInterval@ to microseconds
asTimeout :: TimeInterval -> Int
asTimeout (TimeInterval u v) = timeToMicros u v

-- | Convenience for making timeouts; e.g.,
--
-- > receiveTimeout (after 3 Seconds) [ match (\"ok" -> return ()) ]
--
after :: Int -> TimeUnit -> Int
after n m = timeToMicros m n

-- | Convenience for making 'TimeInterval'; e.g.,
--
-- > let ti = within 5 Seconds in .....
--
within :: Int -> TimeUnit -> TimeInterval
within n m = TimeInterval m n

-- | given a number, produces a @TimeInterval@ of microseconds
microSeconds :: Int -> TimeInterval
microSeconds = TimeInterval Micros

-- | given a number, produces a @TimeInterval@ of milliseconds
milliSeconds :: Int -> TimeInterval
milliSeconds = TimeInterval Millis

-- | given a number, produces a @TimeInterval@ of seconds
seconds :: Int -> TimeInterval
seconds = TimeInterval Seconds

-- | given a number, produces a @TimeInterval@ of minutes
minutes :: Int -> TimeInterval
minutes = TimeInterval Minutes

-- | given a number, produces a @TimeInterval@ of hours
hours :: Int -> TimeInterval
hours = TimeInterval Hours

-- TODO: is timeToMicros efficient enough?

-- | converts the supplied @TimeUnit@ to microseconds
{-# INLINE timeToMicros #-}
timeToMicros :: TimeUnit -> Int -> Int
timeToMicros Micros  us   = us
timeToMicros Millis  ms   = ms  * (10 ^ (3 :: Int)) -- (1000µs == 1ms)
timeToMicros Seconds secs = timeToMicros Millis  (secs * milliSecondsPerSecond)
timeToMicros Minutes mins = timeToMicros Seconds (mins * secondsPerMinute)
timeToMicros Hours   hrs  = timeToMicros Minutes (hrs  * minutesPerHour)
timeToMicros Days    days = timeToMicros Hours   (days * hoursPerDay)

{-# INLINE hoursPerDay #-}
hoursPerDay :: Int
hoursPerDay = 60

{-# INLINE minutesPerHour #-}
minutesPerHour :: Int
minutesPerHour = 60

{-# INLINE secondsPerMinute #-}
secondsPerMinute :: Int
secondsPerMinute = 60

{-# INLINE milliSecondsPerSecond #-}
milliSecondsPerSecond :: Int
milliSecondsPerSecond = 1000

{-# INLINE microSecondsPerSecond #-}
microSecondsPerSecond :: Int
microSecondsPerSecond = 1000000

-- timeouts/delays (microseconds)

-- | Constructs an inifinite 'Timeout'.
infiniteWait :: Timeout
infiniteWait = Nothing

-- | Constructs a no-wait 'Timeout'
noWait :: Timeout
noWait = Just 0

-- | Sends the calling process @TimeoutNotification tag@ after @time@ microseconds
timeout :: Int -> Tag -> ProcessId -> Process ()
timeout time tag p =
  void $ spawnLocal $
               do liftIO $ threadDelay time
                  send p (TimeoutNotification tag)

-- Converting to/from Data.Time.Clock NominalDiffTime

-- | given a @TimeInterval@, provide an equivalent @NominalDiffTim@
timeIntervalToDiffTime :: TimeInterval -> NominalDiffTime
timeIntervalToDiffTime ti = microsecondsToNominalDiffTime (fromIntegral $ asTimeout ti)

-- | given a @NominalDiffTim@@, provide an equivalent @TimeInterval@
diffTimeToTimeInterval :: NominalDiffTime -> TimeInterval
diffTimeToTimeInterval dt = microSeconds $ (fromIntegral (round (dt * 1000000) :: Integer))

-- | given a @Delay@, provide an equivalent @NominalDiffTim@
delayToDiffTime :: Delay -> NominalDiffTime
delayToDiffTime (Delay ti) = timeIntervalToDiffTime ti
delayToDiffTime Infinity   = error "trying to convert Delay.Infinity to a NominalDiffTime"
delayToDiffTime (NoDelay)  = microsecondsToNominalDiffTime 0

-- | given a @NominalDiffTim@@, provide an equivalent @Delay@
diffTimeToDelay :: NominalDiffTime -> Delay
diffTimeToDelay dt = Delay $ diffTimeToTimeInterval dt

-- | Create a 'NominalDiffTime' from a number of microseconds.
microsecondsToNominalDiffTime :: Integer -> NominalDiffTime
microsecondsToNominalDiffTime x = fromRational (x % (fromIntegral microSecondsPerSecond))

-- tenYearsAsMicroSeconds :: Integer
-- tenYearsAsMicroSeconds = 10 * 365 * 24 * 60 * 60 * 1000000

-- | Allow @(+)@ and @(-)@ operations on @TimeInterval@s
instance Num TimeInterval where
  t1 + t2 = microSeconds $ asTimeout t1 + asTimeout t2
  t1 - t2 = microSeconds $ asTimeout t1 - asTimeout t2
  _ * _ = error "trying to multiply two TimeIntervals"
  abs t = microSeconds $ abs (asTimeout t)
  signum t = if (asTimeout t) == 0
              then 0
              else if (asTimeout t) < 0 then -1
                                        else 1
  fromInteger _ = error "trying to call fromInteger for a TimeInterval. Cannot guess units"

-- | Allow @(+)@ and @(-)@ operations on @Delay@s
instance Num Delay where
  NoDelay     + x          = x
  Infinity    + _          = Infinity
  x           + NoDelay    = x
  _           + Infinity   = Infinity
  (Delay t1 ) + (Delay t2) = Delay (t1 + t2)

  NoDelay     - x          = x
  Infinity    - _          = Infinity
  x           - NoDelay    = x
  _           - Infinity   = Infinity
  (Delay t1 ) - (Delay t2) = Delay (t1 - t2)

  _ * _ = error "trying to multiply two Delays"

  abs NoDelay   = NoDelay
  abs Infinity  = Infinity
  abs (Delay t) = Delay (abs t)

  signum (NoDelay) = 0
  signum Infinity  = 1
  signum (Delay t) = Delay (signum t)

  fromInteger 0 = NoDelay
  fromInteger _ = error "trying to call fromInteger for a Delay. Cannot guess units"

