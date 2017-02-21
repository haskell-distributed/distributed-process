{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.ManagedProcess.Server.Priority
-- Copyright   :  (c) Tim Watson 2012 - 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Prioritised Server portion of the /Managed Process/ API.
-----------------------------------------------------------------------------
module Control.Distributed.Process.ManagedProcess.Server.Priority
  ( prioritiseCall
  , prioritiseCall_
  , prioritiseCast
  , prioritiseCast_
  , prioritiseInfo
  , prioritiseInfo_
  , setPriority
  ) where

import Control.Distributed.Process hiding (call, Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.ManagedProcess.Internal.Types
import Control.Distributed.Process.Serializable
import Prelude hiding (init)

-- | Sets an explicit priority
setPriority :: Int -> Priority m
setPriority = Priority

-- | Prioritise a call handler, ignoring the server's state
prioritiseCall_ :: forall s a b . (Serializable a, Serializable b)
                => (a -> Priority b)
                -> DispatchPriority s
prioritiseCall_ h = prioritiseCall (const h)

-- | Prioritise a call handler
prioritiseCall :: forall s a b . (Serializable a, Serializable b)
               => (s -> a -> Priority b)
               -> DispatchPriority s
prioritiseCall h = PrioritiseCall (unCall . h)
  where
    unCall :: (a -> Priority b) -> P.Message -> Process (Maybe (Int, P.Message))
    unCall h' m = fmap (matchPrioritise m h') (unwrapMessage m)

    matchPrioritise :: P.Message
                    -> (a -> Priority b)
                    -> Maybe (Message a b)
                    -> Maybe (Int, P.Message)
    matchPrioritise msg p msgIn
      | (Just a@(CallMessage m _)) <- msgIn
      , True  <- isEncoded msg = Just (getPrio $ p m, wrapMessage a)
      | (Just   (CallMessage m _)) <- msgIn
      , False <- isEncoded msg = Just (getPrio $ p m, msg)
      | otherwise              = Nothing

-- | Prioritise a cast handler, ignoring the server's state
prioritiseCast_ :: forall s a . (Serializable a)
                => (a -> Priority ())
                -> DispatchPriority s
prioritiseCast_ h = prioritiseCast (const h)

-- | Prioritise a cast handler
prioritiseCast :: forall s a . (Serializable a)
               => (s -> a -> Priority ())
               -> DispatchPriority s
prioritiseCast h = PrioritiseCast (unCast . h)
  where
    unCast :: (a -> Priority ()) -> P.Message -> Process (Maybe (Int, P.Message))
    unCast h' m = fmap (matchPrioritise m h') (unwrapMessage m)

    matchPrioritise :: P.Message
                    -> (a -> Priority ())
                    -> Maybe (Message a ())
                    -> Maybe (Int, P.Message)
    matchPrioritise msg p msgIn
      | (Just a@(CastMessage m)) <- msgIn
      , True  <- isEncoded msg = Just (getPrio $ p m, wrapMessage a)
      | (Just   (CastMessage m)) <- msgIn
      , False <- isEncoded msg = Just (getPrio $ p m, msg)
      | otherwise              = Nothing

-- | Prioritise an info handler, ignoring the server's state
prioritiseInfo_ :: forall s a . (Serializable a)
                => (a -> Priority ())
                -> DispatchPriority s
prioritiseInfo_ h = prioritiseInfo (const h)

-- | Prioritise an info handler
prioritiseInfo :: forall s a . (Serializable a)
               => (s -> a -> Priority ())
               -> DispatchPriority s
prioritiseInfo h = PrioritiseInfo (unMsg . h)
  where
    unMsg :: (a -> Priority ()) -> P.Message -> Process (Maybe (Int, P.Message))
    unMsg h' m = fmap (matchPrioritise m h') (unwrapMessage m)

    matchPrioritise :: P.Message
                    -> (a -> Priority ())
                    -> Maybe a
                    -> Maybe (Int, P.Message)
    matchPrioritise msg p msgIn
      | (Just m') <- msgIn
      , True <- isEncoded msg  = Just (getPrio $ p m', wrapMessage m')
      | (Just m') <- msgIn
      , False <- isEncoded msg = Just (getPrio $ p m', msg)
      | otherwise              = Nothing
