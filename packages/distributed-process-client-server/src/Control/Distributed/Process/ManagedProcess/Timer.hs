{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.ManagedProcess.Timer
-- Copyright   :  (c) Tim Watson 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a wrap around a simple 'Timer' that can be started,
-- stopped, reset, cleared, and read. A convenient function is provided for
-- creating a @Match@ expression for the timer.
--
-- [Notes]
--
-- The timers defined in this module are based on a @TVar Bool@. When the
-- client program is @-threaded@ (i.e. @rtsSupportsBoundThreads == True@), then
-- the timers are set using @registerDelay@, which is very efficient and relies
-- only no the RTS IO Manager. When we're not @-threaded@, we fall back to using
-- "Control.Distributed.Process.Extras.Timer" to set the @TVar@, which has much
-- the same effect, but requires us to spawn a process to handle setting the
-- @TVar@ - a process which could theoretically die before setting the variable.
--
module Control.Distributed.Process.ManagedProcess.Timer
  ( Timer(timerDelay)
  , TimerKey
  , delayTimer
  , startTimer
  , stopTimer
  , resetTimer
  , clearTimer
  , matchTimeout
  , matchKey
  , matchRun
  , isActive
  , readTimer
  , TimedOut(..)
  ) where

import Control.Concurrent (rtsSupportsBoundThreads)
import Control.Concurrent.STM hiding (check)
import Control.Distributed.Process
  ( matchSTM
  , Process
  , ProcessId
  , Match
  , Message
  , liftIO
  )
import qualified Control.Distributed.Process as P
  ( liftIO
  )
import Control.Distributed.Process.Extras.Time (asTimeout, Delay(..))
import Control.Distributed.Process.Extras.Timer
  ( cancelTimer
  , runAfter
  , TimerRef
  )
import Data.Binary (Binary)
import Data.Maybe (isJust, fromJust)
import Data.Typeable (Typeable)
import GHC.Conc (registerDelay)
import GHC.Generics

--------------------------------------------------------------------------------
-- Timeout Management                                                         --
--------------------------------------------------------------------------------

-- | A key for storing timers in prioritised process backing state.
type TimerKey = Int

-- | Used during STM reads on Timers and to implement blocking. Since timers
-- can be associated with a "TimerKey", the second constructor for this type
-- yields a key indicating whic "Timer" it refers to. Note that the user is
-- responsible for establishing and maintaining the mapping between @Timer@s
-- and their keys.
data TimedOut = TimedOut | Yield TimerKey
  deriving (Eq, Show, Typeable, Generic)
instance Binary TimedOut where

-- | We hold timers in 2 states, each described by a Delay.
-- isActive = isJust . mtSignal
-- the TimerRef is optional since we only use the Timer module from extras
-- when we're unable to registerDelay (i.e. not running under -threaded)
data Timer = Timer { timerDelay :: Delay
                   , mtPidRef   :: Maybe TimerRef
                   , mtSignal   :: Maybe (TVar Bool)
                   }

-- | @True@ if a @Timer@ is currently active.
isActive :: Timer -> Bool
isActive = isJust . mtSignal

-- | Creates a default @Timer@ which is inactive.
delayTimer :: Delay -> Timer
delayTimer d = Timer d noPid noTVar
  where
    noPid  = Nothing :: Maybe ProcessId
    noTVar = Nothing :: Maybe (TVar Bool)

-- | Starts a @Timer@
-- Will use the GHC @registerDelay@ API if @rtsSupportsBoundThreads == True@
startTimer :: Delay -> Process Timer
startTimer d
  | Delay t <- d = establishTimer t
  | otherwise    = return $ delayTimer d
  where
    establishTimer t'
      | rtsSupportsBoundThreads = do sig <- liftIO $ registerDelay (asTimeout t')
                                     return Timer { timerDelay = d
                                                  , mtPidRef = Nothing
                                                  , mtSignal = Just sig
                                                  }
      | otherwise = do
          tSig  <- liftIO $ newTVarIO False
          -- NB: runAfter spawns a process, which is defined in terms of
          -- expectTimeout (asTimeout t) :: Process (Maybe CancelTimer)
          --
          tRef <- runAfter t' $ P.liftIO $ atomically $ writeTVar tSig True
          return Timer { timerDelay  = d
                       , mtPidRef = Just tRef
                       , mtSignal = Just tSig
                       }

-- | Stops a previously started @Timer@. Has no effect if the @Timer@ is inactive.
stopTimer :: Timer -> Process Timer
stopTimer t@Timer{..} = do
  clearTimer mtPidRef
  return t { mtPidRef = Nothing
           , mtSignal = Nothing
           }

-- | Clears and restarts a @Timer@.
resetTimer :: Timer -> Delay -> Process Timer
resetTimer Timer{..} d = clearTimer mtPidRef >> startTimer d

-- | Clears/cancels a running timer. Has no effect if the @Timer@ is inactive.
clearTimer :: Maybe TimerRef -> Process ()
clearTimer ref
  | isJust ref = cancelTimer (fromJust ref)
  | otherwise  = return ()

-- | Creates a @Match@ for a given timer, for use with Cloud Haskell's messaging
-- primitives for selective receives.
matchTimeout :: Timer -> [Match (Either TimedOut Message)]
matchTimeout t@Timer{..}
    | isActive t = [ matchSTM (readTimer $ fromJust mtSignal)
                              (return . Left) ]
    | otherwise  = []

-- | Create a match expression for a given @Timer@. When the timer expires
-- (i.e. the "TVar Bool" is set to @True@), the "Match" will return @Yield i@,
-- where @i@ is the given "TimerKey".
matchKey :: TimerKey -> Timer -> [Match (Either TimedOut Message)]
matchKey i t@Timer{..}
  | isActive t = [matchSTM (readTVar (fromJust mtSignal) >>= \expired ->
                               if expired then return (Yield i) else retry)
                           (return . Left)]
  | otherwise  = []

-- | As "matchKey", but instead of a returning @Yield i@, the generated "Match"
-- handler evaluates the first argument - and expression from "TimerKey" to
-- @Process Message@ - to determine its result.
matchRun :: (TimerKey -> Process Message)
         -> TimerKey
         -> Timer
         -> [Match Message]
matchRun f k t@Timer{..}
  | isActive t = [matchSTM (readTVar (fromJust mtSignal) >>= \expired ->
                               if expired then return k else retry) f]
  | otherwise  = []

-- | Reads a given @TVar Bool@ for a timer, and returns @STM TimedOut@ once the
-- variable is set to true. Will @retry@ in the meanwhile.
readTimer :: TVar Bool -> STM TimedOut
readTimer t = do
   expired <- readTVar t
   if expired then return TimedOut
              else retry
