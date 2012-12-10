-- | General utilities for use with distributed-process-platform.
-- These entities are mainly exported via the top level @Platform@ module
-- and should be imported from there in most cases.
module Control.Distributed.Platform.Utils 
  (
    milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
  ) where

import Control.Distributed.Platform.Internal.Types

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- time interval/unit handling

-- | converts the supplied TimeInterval to milliseconds
intervalToMs :: TimeInterval -> Int
intervalToMs (TimeInterval u v) = timeToMs u v

-- | given a number, produces a `TimeInterval' of milliseconds
milliseconds :: Int -> TimeInterval
milliseconds = TimeInterval Millis

-- | given a number, produces a `TimeInterval' of seconds
seconds :: Int -> TimeInterval
seconds = TimeInterval Seconds

-- | given a number, produces a `TimeInterval' of minutes
minutes :: Int -> TimeInterval
minutes = TimeInterval Minutes

-- | given a number, produces a `TimeInterval' of hours
hours :: Int -> TimeInterval
hours = TimeInterval Hours

-- TODO: timeToMs is not exactly efficient and we need to scale it up to
--       deal with days, months, years, etc

-- | converts the supplied TimeUnit to milliseconds
timeToMs :: TimeUnit -> Int -> Int
timeToMs Millis  ms   = ms
timeToMs Seconds sec  = sec * 1000
timeToMs Minutes mins = (mins * 60) * 1000
timeToMs Hours   hrs  = ((hrs * 60) * 60) * 1000
  