{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE StandaloneDeriving         #-}

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
  ( -- * Prioritising API Handlers
    prioritiseCall
  , prioritiseCall_
  , prioritiseCast
  , prioritiseCast_
  , prioritiseInfo
  , prioritiseInfo_
  , setPriority
    -- * Creating Filters
  , check
  , raw
  , api
  , api_
  , message
  , refuse
  , reject
  , rejectApi
  , store
  , Filter()
  , DispatchFilter()
  , Message()
  ) where

import Control.Distributed.Process hiding (call, Message)
import qualified Control.Distributed.Process as P (Message)
import Control.Distributed.Process.ManagedProcess.Internal.Types
import Control.Distributed.Process.Serializable
import Prelude hiding (init)

data RejectedByServer = RejectedByServer deriving (Show)

data FilterHandler s =
    forall m . (Serializable m) =>
    HandlePure
    {
      pureCheck :: s -> m -> Process Bool
    , handler :: s -> m -> Process (Filter s)
    }
  | forall m b . (Serializable m, Serializable b) =>
    HandleApi
    {
      apiCheck :: s -> m -> Process Bool
    , apiHandler :: s -> Message m b -> Process (Filter s)
    }
  | HandleRaw
    {
      rawCheck :: s -> P.Message -> Process Bool
    , rawHandler :: s -> P.Message -> Process (Maybe (Filter s))
    }
  | HandleState { stateHandler :: s -> Process (Maybe (Filter s)) }

{-
check :: forall c s m . (Check c s m)
      => c -> (s -> Process (Filter s)) -> s -> m -> Process (Filter s)
-}
check :: forall s . FilterHandler s -> DispatchFilter s
check h
  | HandlePure{..}  <- h = FilterAny $ \s m -> pureCheck s m >>= procUnless s m handler
  | HandleRaw{..}   <- h = FilterRaw $ \s m -> do
      c <- rawCheck s m
      if c then return $ Just $ FilterOk s
           else rawHandler s m
  | HandleState{..} <- h = FilterState stateHandler
  | HandleApi{..}   <- h = FilterApi $ \s m@(CallMessage m' _) -> do
      c <- apiCheck s m'
      if c then return $ FilterOk s
           else apiHandler s m

  where
    procUnless s _ _ True  = return $ FilterOk s
    procUnless s m h' False = h' s m

raw :: forall s .
       (s -> P.Message -> Process Bool)
    -> (s -> P.Message -> Process (Maybe (Filter s)))
    -> FilterHandler s
raw = HandleRaw

api :: forall s m b . (Serializable m, Serializable b)
    => (s -> m -> Process Bool)
    -> (s -> Message m b -> Process (Filter s))
    -> FilterHandler s
api = HandleApi

api_ :: forall m b s . (Serializable m, Serializable b)
     => (m -> Process Bool)
     -> (s -> Message m b -> Process (Filter s))
     -> FilterHandler s
api_ c h = api (const $ c) h

message :: forall s m . (Serializable m)
        => (s -> m -> Process Bool)
        -> (s -> m -> Process (Filter s))
        -> FilterHandler s
message = HandlePure

reject :: forall s m r . (Show r)
       => r -> s -> m -> Process (Filter s)
reject r = \s _ -> do return $ FilterReject (show r) s

rejectApi :: forall s m b r . (Show r, Serializable m, Serializable b)
          => r -> s -> Message m b -> Process (Filter s)
rejectApi r = \s m -> do let r' = show r
                         rejectToCaller m r'
                         return $ FilterSkip s

store :: (s -> s) -> DispatchFilter s
store f = FilterState $ return . Just . FilterOk . f

refuse :: forall s m . (Serializable m)
       => (m -> Bool)
       -> DispatchFilter s
refuse c = check $ message (const $ \m -> return $ c m) (reject RejectedByServer)

{-

apiCheck :: forall s m r . (Serializable m, Serializable r)
      => (s -> Message m r -> Bool)
      -> (s -> Message m r -> Process (Filter s))
      -> DispatchFilter s
apiCheck c h = checkM (\s m -> return $ c s m) h

apiReject
-}

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
