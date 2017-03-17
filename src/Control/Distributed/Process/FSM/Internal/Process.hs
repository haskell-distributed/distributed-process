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

module Control.Distributed.Process.FSM.Internal.Process
where

import Control.Distributed.Process
 ( Process
 , ProcessId
 , SendPort
 , sendChan
 , spawnLocal
 , liftIO
 )
import qualified Control.Distributed.Process as P
 ( Message
 )
import Control.Distributed.Process.Extras (ExitReason(..))
import Control.Distributed.Process.Extras.Time (Delay(Infinity))
import Control.Distributed.Process.FSM.Internal.Types hiding (liftIO)
import Control.Distributed.Process.ManagedProcess
 ( ProcessDefinition(..)
 , PrioritisedProcessDefinition
 , ProcessAction()
 , Action
 , InitHandler
 , InitResult(..)
 , defaultProcess
 , prioritised
 , GenProcess
 , setProcessState
 , push
 )
import qualified Control.Distributed.Process.ManagedProcess as MP (pserve)
import Control.Distributed.Process.ManagedProcess.Server
 ( handleRaw
 , handleInfo
 , continue
 )
import Data.Maybe (fromJust)
import qualified Data.Sequence as Q (empty)
-- import Control.Distributed.Process.Serializable (Serializable)
-- import Control.Monad (void)
-- import Data.Binary (Binary)
-- import Data.Typeable (Typeable)
-- import GHC.Generics

start ::  forall s d . (Show s) => s -> d -> (Step s d) -> Process ProcessId
start s d p = spawnLocal $ run s d p

run :: forall s d . (Show s) => s -> d -> (Step s d) -> Process ()
run s d p = MP.pserve (s, d, p) fsmInit processDefinition

fsmInit :: forall s d . (Show s) => InitHandler (s, d, Step s d) (FsmState s d)
fsmInit (st, sd, prog) = return $ InitOk (FsmState st sd prog) Infinity

processDefinition :: forall s d . (Show s) => PrioritisedProcessDefinition (FsmState s d)
processDefinition =
  defaultProcess
  {
    infoHandlers = [ handleInfo handleRpcRawInputs
                   , handleRaw  handleAllRawInputs
                   ]
  } `prioritised` []

handleRpcRawInputs :: forall s d . (Show s) => FsmState s d
                   -> (P.Message, SendPort P.Message)
                   -> Action (FsmState s d)
handleRpcRawInputs st@FsmState{..} (msg, port) = do
  let runState = State fsmName fsmData msg (sendChan port) Q.empty
  handleInput st runState msg

handleAllRawInputs :: forall s d. (Show s) => FsmState s d
                   -> P.Message
                   -> Action (FsmState s d)
handleAllRawInputs st@FsmState{..} msg = do
  let runState = State fsmName fsmData msg (const $ return ()) Q.empty
  handleInput st runState msg

handleInput :: forall s d . (Show s) => FsmState s d
            -> State s d
            -> P.Message
            -> Action (FsmState s d)
handleInput st@FsmState{..} runState msg = do
  liftIO $ putStrLn $ "apply " ++ (show fsmProg)
  res <- apply runState msg fsmProg
  liftIO $ putStrLn $ "got a result: " ++ (show res)
  case res of
    Just res' -> applyTransitions st res' []
    Nothing   -> continue st
