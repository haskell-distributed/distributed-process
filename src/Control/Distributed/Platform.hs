-- | [Cloud Haskell Platform]
--
module Control.Distributed.Platform
  (
    -- exported time interval handling
    milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
    -- timeouts and time interval types
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
