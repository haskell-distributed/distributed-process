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

import Control.Distributed.Process (wrapMessage)
import Control.Distributed.Process.Extras (ExitReason)
import Control.Distributed.Process.Extras.Time
 ( TimeInterval
 )
import Control.Distributed.Process.ManagedProcess
 ( processState
 , setProcessState
 , runAfter
 , Priority
 )
import Control.Distributed.Process.ManagedProcess.Server.Priority (setPriority)
import qualified Control.Distributed.Process.ManagedProcess.Internal.Types as MP (liftIO)
import Control.Distributed.Process.FSM.Internal.Types
import Control.Distributed.Process.Serializable (Serializable)

initState :: forall s d . s -> d -> Step s d
initState = Yield

event :: (Serializable m) => Event m
event = Wait

pevent :: (Serializable m) => Int -> Event m
pevent = WaitP . setPriority

enter :: forall s d . s -> FSM s d (Transition s d)
enter = return . Enter

postpone :: forall s d . FSM s d (Transition s d)
postpone = return Postpone

putBack :: forall s d . FSM s d (Transition s d)
putBack = return PutBack

nextEvent :: forall s d m . (Serializable m) => m -> FSM s d (Transition s d)
nextEvent m = return $ Push (wrapMessage m)

publishEvent :: forall s d m . (Serializable m) => m -> FSM s d (Transition s d)
publishEvent m = return $ Enqueue (wrapMessage m)

resume :: forall s d . FSM s d (Transition s d)
resume = return Remain

reply :: forall s d r . (Serializable r) => FSM s d r -> Step s d
reply = Reply

timeout :: Serializable m => TimeInterval -> m -> FSM s d (Transition s d)
timeout t m = return $ Eval $ runAfter t m

stop :: ExitReason -> FSM s d (Transition s d)
stop = return . Stop

set :: forall s d . (d -> d) -> FSM s d ()
set f = addTransition $ Eval $ do
  MP.liftIO $ putStrLn "setting state"
  processState >>= \s -> setProcessState $ s { stData = (f $ stData s) }

put :: forall s d . d -> FSM s d ()
put d = addTransition $ Eval $ do
  processState >>= \s -> setProcessState $ s { stData = d }

(.|) :: Step s d -> Step s d -> Step s d
(.|) = Alternate
infixr 9 .|

pick :: Step s d -> Step s d -> Step s d
pick = Alternate

(^.) :: Step s d -> Step s d -> Step s d
(^.) = Init
infixr 9 ^.

begin :: Step s d -> Step s d -> Step s d
begin = Init

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

(*>) :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
(*>) = SafeWait
infixr 9 *>

safeWait :: forall s d m . (Serializable m) => Event m -> Step s d -> Step s d
safeWait = SafeWait

(~@) :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
(~@) = Perhaps
infixr 9 ~@

atState :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
atState = Perhaps

whenStateIs :: forall s d . (Eq s) => s -> Step s d
whenStateIs s = s ~@ resume

allState :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
allState = Always

always :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
always = Always

(~?) :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
(~?) = Matching

matching :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
matching = Matching
