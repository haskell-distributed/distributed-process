-- | [Cloud Haskell Platform]
--
module Control.Distributed.Platform
  (
    -- extra primitives
    spawnLinkLocal
  , spawnMonitorLocal
    -- time interval handling
  , milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
  , Timeout(..)
  , TimeInterval
  , TimeUnit
  , TimerRef
    -- exported timer operations
  , sleep
  , sendAfter
  , startTimer
  , resetTimer
  , cancelTimer
  ) where

import Control.Distributed.Platform.Internal.Primitives
import Control.Distributed.Platform.Internal.Types
import Control.Distributed.Platform.Timer
  ( milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
  , sleep
  , sendAfter
  , startTimer
  , resetTimer
  , cancelTimer
  , TimerRef
  )
