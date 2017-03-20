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
import Control.Distributed.Process.Extras.Time (Delay(Infinity))
import Control.Distributed.Process.FSM.Internal.Types hiding (liftIO)
import Control.Distributed.Process.ManagedProcess
 ( ProcessDefinition(..)
 , PrioritisedProcessDefinition(filters)
 , Action
 , InitHandler
 , InitResult(..)
 , defaultProcess
 , prioritised
 )
import qualified Control.Distributed.Process.ManagedProcess as MP (pserve)
import Control.Distributed.Process.ManagedProcess.Server.Priority (safely)
import Control.Distributed.Process.ManagedProcess.Server
 ( handleRaw
 , handleInfo
 , continue
 )
import Control.Distributed.Process.ManagedProcess.Internal.Types
 ( ExitSignalDispatcher(..)
 )
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

fsmInit :: forall s d . (Show s) => InitHandler (s, d, Step s d) (State s d)
fsmInit (st, sd, prog) =
  return $ InitOk (State st sd prog Nothing (const $ return ()) Q.empty) Infinity

processDefinition :: forall s d . (Show s) => PrioritisedProcessDefinition (State s d)
processDefinition =
  (prioritised
    defaultProcess
    {
      infoHandlers = [ handleInfo handleRpcRawInputs
                     , handleRaw  handleAllRawInputs
                     ]
    , exitHandlers = [ ExitSignalDispatcher (\s _ m -> handleAllRawInputs s m >>= return . Just)
                     ]
    } []) { filters = [safely] }

handleRpcRawInputs :: forall s d . (Show s) => State s d
                   -> (P.Message, SendPort P.Message)
                   -> Action (State s d)
handleRpcRawInputs st@State{..} (msg, port) =
  handleInput msg $ st { stReply = (sendChan port), stTrans = Q.empty }

handleAllRawInputs :: forall s d. (Show s) => State s d
                   -> P.Message
                   -> Action (State s d)
handleAllRawInputs st@State{..} msg =
  handleInput msg $ st { stReply = noOp, stTrans = Q.empty }

noOp :: P.Message -> Process ()
noOp = const $ return ()

handleInput :: forall s d . (Show s)
            => P.Message
            -> State s d
            -> Action (State s d)
handleInput msg st@State{..} = do
  liftIO $ putStrLn $ "handleInput: " ++ (show stName)
  liftIO $ putStrLn $ "apply " ++ (show stProg)
  res <- apply st msg stProg
  liftIO $ putStrLn $ "got a result: " ++ (show res)
  case res of
    Just res' -> applyTransitions res' []
    Nothing   -> continue st
