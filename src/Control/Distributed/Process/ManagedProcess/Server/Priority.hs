{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}

module Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
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
import Control.Distributed.Process.Platform.ManagedProcess.Internal.Types
import Control.Distributed.Process.Serializable
import Prelude hiding (init)

setPriority :: Int -> Priority m
setPriority = Priority

prioritiseCall_ :: forall s a b . (Serializable a, Serializable b)
                => (a -> Priority b)
                -> DispatchPriority s
prioritiseCall_ h = prioritiseCall (\_ -> h)

prioritiseCall :: forall s a b . (Serializable a, Serializable b)
               => (s -> a -> Priority b)
               -> DispatchPriority s
prioritiseCall h = PrioritiseCall (\s -> unCall $ h s)
  where
    unCall :: (a -> Priority b) -> P.Message -> Process (Maybe (Int, P.Message))
    unCall h' m = unwrapMessage m >>= return . matchPrioritise m h'

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

prioritiseCast_ :: forall s a . (Serializable a)
                => (a -> Priority ())
                -> DispatchPriority s
prioritiseCast_ h = prioritiseCast (\_ -> h)

prioritiseCast :: forall s a . (Serializable a)
               => (s -> a -> Priority ())
               -> DispatchPriority s
prioritiseCast h = PrioritiseCast (\s -> unCast $ h s)
  where
    unCast :: (a -> Priority ()) -> P.Message -> Process (Maybe (Int, P.Message))
    unCast h' m = unwrapMessage m >>= return . matchPrioritise m h'

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

prioritiseInfo_ :: forall s a . (Serializable a)
                => (a -> Priority ())
                -> DispatchPriority s
prioritiseInfo_ h = prioritiseInfo (\_ -> h)

prioritiseInfo :: forall s a . (Serializable a)
               => (s -> a -> Priority ())
               -> DispatchPriority s
prioritiseInfo h = PrioritiseInfo (\s -> unMsg $ h s)
  where
    unMsg :: (a -> Priority ()) -> P.Message -> Process (Maybe (Int, P.Message))
    unMsg h' m = unwrapMessage m >>= return . matchPrioritise m h'

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

