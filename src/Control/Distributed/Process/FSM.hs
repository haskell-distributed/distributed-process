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
import qualified Control.Distributed.Process.ManagedProcess.Internal.Types as MP (liftIO)
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

(~@) :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
(~@) = Perhaps
infixr 9 ~@

atState :: forall s d . (Eq s) => s -> FSM s d (Transition s d) -> Step s d
atState = Perhaps

allState :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
allState = Always

always :: forall s d m . (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
always = Always

(~?) :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
(~?) = Matching

matching :: forall s d m . (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
matching = Matching
