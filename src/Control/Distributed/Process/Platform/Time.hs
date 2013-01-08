{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Time
-- Copyright   :  (c) Tim Watson, Jeff Epstein
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainers :  Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides facilities for working with time delays and timeouts.
-- The type 'Timeout' and the 'timeout' family of functions provide mechanisms
-- for working with @threadDelay@-like behaviour operates on microsecond values.
--
-- The 'TimeInterval' and 'TimeUnit' related functions provide an abstraction
-- for working with various time intervals and the 'Delay' type provides a
-- corrolary to 'timeout' that works with these.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Time 
  ( -- time interval handling
    milliseconds
  , seconds
  , minutes
  , hours
  , intervalToMs
  , timeToMs
  , TimeInterval
  , TimeUnit
  , Delay(..)
  
  -- timeouts
  , Timeout
  , TimeoutNotification(..)
  , timeout
  , infiniteWait
  , noWait
  ) where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Platform.Internal.Types
import Control.Monad (void)
import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Defines the time unit for a Timeout value
data TimeUnit = Days | Hours | Minutes | Seconds | Millis
    deriving (Typeable, Show)
$(derive makeBinary ''TimeUnit)

data TimeInterval = TimeInterval TimeUnit Int
    deriving (Typeable, Show)
$(derive makeBinary ''TimeInterval)

data Delay = Delay TimeInterval | Infinity

-- | Represents a /timeout/ in terms of microseconds, where 'Nothing' stands for
-- infinity and @Just 0@, no-delay.
type Timeout = Maybe Int

-- | Send to a process when a timeout expires.
data TimeoutNotification = TimeoutNotification Tag
       deriving (Typeable)

instance Binary TimeoutNotification where
       get = fmap TimeoutNotification $ get
       put (TimeoutNotification n) = put n

-- time interval/unit handling (milliseconds)

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

-- TODO: timeToMs is not exactly efficient and we may want to scale it up

-- | converts the supplied @TimeUnit@ to milliseconds
timeToMs :: TimeUnit -> Int -> Int
timeToMs Millis  ms   = ms
timeToMs Seconds sec  = sec * 1000
timeToMs Minutes mins = (mins * 60) * 1000
timeToMs Hours   hrs  = ((hrs * 60) * 60) * 1000
timeToMs Days    days = (((days * 24) * 60) * 60) * 1000

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
       