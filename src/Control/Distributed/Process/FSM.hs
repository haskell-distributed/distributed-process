{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE RankNTypes                 #-}

module Control.Distributed.Process.FSM where

import Control.Distributed.Process (Process)
import Control.Distributed.Process.Extras
 ( ExitReason(ExitShutdown)
 )
import Control.Distributed.Process.Extras.Time
 ( TimeInterval
 , seconds
 )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad (void)
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO)
import qualified Control.Monad.State.Strict as ST
  ( MonadState
  , StateT
  , get
  , lift
  , runStateT
  )
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics

data State s d m = State

newtype FSM s d m o = FSM {
   unFSM :: ST.StateT (State s d m) Process o
 }
 deriving ( Functor
          , Monad
          , ST.MonadState (State s d m)
          , MonadIO
          , MonadFix
          , Typeable
          , Applicative
          )

data Action = Consume | Produce | Skip
data Transition s m = Remain | PutBack m | Change s
data Event m = Event

data Step s d where
  Start     :: s -> d -> Step s d
  Await     :: (Serializable m) => Event m -> Step s d -> Step s d
  Always    :: FSM s d m (Transition s d) -> Step s d
  Perhaps   :: (Eq s) => s -> FSM s d m (Transition s d) -> Step s d
  Matching  :: (m -> Bool) -> FSM s d m (Transition s d) -> Step s d
  Sequence  :: Step s d -> Step s d -> Step s d
  Alternate :: Step s d -> Step s d -> Step s d
  Reply     :: (Serializable r) => FSM s f m r -> Step s d

type Pipeline = forall s d . Step s d

initState :: forall s d . s -> d -> Step s d
initState = Start

-- endState :: Action -> State
-- endState = undefined

enter :: forall s d m . s -> FSM s d m (Transition s d)
enter = undefined

stopWith :: ExitReason -> Action
stopWith = undefined

event :: (Serializable m) => Event m
event = Event

currentState :: forall s d m . FSM s d m s
currentState = undefined

reply :: forall s d m r . (Serializable r) => FSM s d m r -> Step s d
reply = Reply

timeout :: Serializable a => TimeInterval -> a -> FSM s d m (Transition s d)
timeout = undefined

set :: forall s d m . (d -> d) -> FSM s d m ()
set = undefined

put :: forall s d m . d -> FSM s d m ()
put = undefined

(.|) :: Step s d -> Step s d -> Step s d
(.|) = Alternate
infixr 9 .|

(|>) :: Step s d -> Step s d -> Step s d
(|>) = Sequence
infixr 9 |>

(<|) :: Step s d -> Step s d -> Step s d
(<|) = undefined
infixr 9 <|

(~>) :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
(~>) = Await
infixr 9 ~>

(~@) :: forall s d m . (Eq s) => s -> FSM s d m (Transition s d) -> Step s d
(~@) = Perhaps
infixr 9 ~@

allState :: forall s d m . FSM s d m (Transition s d) -> Step s d
allState = Always

(~?) :: forall s d m . (m -> Bool) -> FSM s d m (Transition s d) -> Step s d
(~?) = Matching

start :: Pipeline -> Process ()
start = const $ return ()

data StateName = On | Off deriving (Eq, Show, Typeable, Generic)
instance Binary StateName where

data Reset = Reset deriving (Eq, Show, Typeable, Generic)
instance Binary Reset where

type StateData = Integer
type ButtonPush = ()
type Stop = ExitReason

initCount :: StateData
initCount = 0

startState :: Step StateName Integer
startState = initState Off initCount

demo :: Step StateName StateData
demo = startState
         |> (event :: Event ButtonPush)
              ~> (  (On  ~@ (set (+1) >> enter Off))
                 .| (Off ~@ (set (+1) >> enter On))
                 ) <| (reply currentState)
         .| (event :: Event Stop)
              ~> ((== ExitShutdown) ~? (timeout (seconds 3) Reset))
         .| (event :: Event Reset) ~> (allState $ put initCount >> enter Off)
--        .| endState $ stopWith ExitNormal
