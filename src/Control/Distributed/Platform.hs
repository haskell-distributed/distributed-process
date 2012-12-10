-- | [Cloud Haskell Platform]
--
module Control.Distributed.Platform
  (
      -- time interval handling
    milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
  , Timeout(..)
  , TimeInterval
  , TimeUnit
  ) where

import Control.Distributed.Platform.Internal.Types
import Control.Distributed.Platform.Utils
