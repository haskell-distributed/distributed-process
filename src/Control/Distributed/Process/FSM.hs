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
import Control.Distributed.Process.ManagedProcess
 ( processState
 , setProcessState
 , runAfter
 )
import Control.Distributed.Process.FSM.Internal.Types
import Control.Distributed.Process.FSM.Internal.Process
 ( start
 )
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad (void)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics

type Pipeline = forall s d . Step s d

initState :: forall s d . s -> d -> Step s d
initState = Yield

enter :: forall s d . s -> FSM s d (Transition s d)
enter = return . Enter

event :: (Serializable m) => Event m
event = Wait

reply :: forall s d r . (Serializable r) => FSM s d r -> Step s d
reply = Reply

timeout :: Serializable m => TimeInterval -> m -> FSM s d (Transition s d)
timeout t m = return $ Eval $ runAfter t m

stop :: ExitReason -> FSM s d (Transition s d)
stop = return . Stop

set :: forall s d . (d -> d) -> FSM s d ()
set f = addTransition $ Eval $ do
  processState >>= \s -> setProcessState $ s { fsmData = (f $ fsmData s) }

put :: forall s d . d -> FSM s d ()
put d = addTransition $ Eval $ do
  processState >>= \s -> setProcessState $ s { fsmData = d }

(.|) :: Step s d -> Step s d -> Step s d
(.|) = Alternate
infixr 9 .|

pick :: Step s d -> Step s d -> Step s d
pick = Alternate

(|>) :: Step s d -> Step s d -> Step s d
(|>) = Sequence
infixr 9 |>

join :: Step s d -> Step s d -> Step s d
join = Sequence

(<|) :: Step s d -> Step s d -> Step s d
(<|) = flip Sequence
-- infixl 9 <|

reverseJoin :: Step s d -> Step s d -> Step s d
reverseJoin = flip Sequence

(~>) :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
(~>) = Await
infixr 9 ~>

await :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
await = Await

(~@) :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
(~@) = Perhaps
infixr 9 ~@

atState :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
atState = Perhaps

allState :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
allState = Always

(~?) :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
(~?) = Matching

matching :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
matching = Matching

{-
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
              ~> (  (On  ~@ (set (+1) >> enter Off)) -- on => off => on is possible with |> here...
                 .| (Off ~@ (set (+1) >> enter On))
                 ) |> (reply currentState)
         .| (event :: Event Stop)
              ~> (  ((== ExitShutdown) ~? (\_ -> timeout (seconds 3) Reset))
                 .| ((const True) ~? (\r -> (liftIO $ putStrLn "stopping...") >> stop r))
                 )
         .| (event :: Event Reset)
              ~> (allState $ \Reset -> put initCount >> enter Off)

-}
