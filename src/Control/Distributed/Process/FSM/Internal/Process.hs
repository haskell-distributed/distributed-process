{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}

module Control.Distributed.Process.FSM.Internal.Process
 ( start
 , run
 ) where

import Control.Distributed.Process
 ( Process
 , ProcessId
 , SendPort
 , sendChan
 , spawnLocal
 , handleMessage
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
 , DispatchFilter
 , defaultProcess
 , prioritised
 )
import qualified Control.Distributed.Process.ManagedProcess as MP (pserve)
import Control.Distributed.Process.ManagedProcess.Server.Priority
 ( safely
 )
import Control.Distributed.Process.ManagedProcess.Server
 ( handleRaw
 , handleInfo
 , continue
 )
import Control.Distributed.Process.ManagedProcess.Internal.Types
 ( ExitSignalDispatcher(..)
 , DispatchPriority(PrioritiseInfo)
 )
import Data.Maybe (isJust)
import qualified Data.Sequence as Q (empty)

-- | Start an FSM process
start ::  forall s d . (Show s, Eq s) => s -> d -> (Step s d) -> Process ProcessId
start s d p = spawnLocal $ run s d p

-- | Run an FSM process. NB: this is a /managed process listen-loop/
-- and will not evaluate to its result until the server process stops.
run :: forall s d . (Show s, Eq s) => s -> d -> (Step s d) -> Process ()
run s d p = MP.pserve (s, d, p) fsmInit (processDefinition p)

fsmInit :: forall s d . (Show s, Eq s) => InitHandler (s, d, Step s d) (State s d)
fsmInit (st, sd, prog) =
  let st' = State st sd prog Nothing (const $ return ()) Q.empty Q.empty
  in return $ InitOk st' Infinity

processDefinition :: forall s d . (Show s) => Step s d -> PrioritisedProcessDefinition (State s d)
processDefinition prog =
  (prioritised
    defaultProcess
    {
      infoHandlers = [ handleInfo handleRpcRawInputs
                     , handleRaw  handleAllRawInputs
                     ]
    , exitHandlers = [ ExitSignalDispatcher (\s _ m -> handleAllRawInputs s m >>= return . Just)
                     ]
    } (walkPFSM prog [])) { filters = (walkFSM prog []) }

-- we should probably make a Foldable (Step s d) for these
walkFSM :: forall s d . Step s d
        -> [DispatchFilter (State s d)]
        -> [DispatchFilter (State s d)]
walkFSM st acc
  | SafeWait  evt act <- st = walkFSM act $ safely (\_ m -> isJust $ decodeToEvent evt m) : acc
  | Await     _   act <- st = walkFSM act acc
  | Sequence  ac1 ac2 <- st = walkFSM ac1 $ walkFSM ac2 acc
  | Init      ac1 ac2 <- st = walkFSM ac1 $ walkFSM ac2 acc
  | Alternate ac1 ac2 <- st = walkFSM ac1 $ walkFSM ac2 acc -- both branches need filter defs
  | otherwise               = acc

walkPFSM :: forall s d . Step s d
         -> [DispatchPriority (State s d)]
         -> [DispatchPriority (State s d)]
walkPFSM st acc
  | SafeWait  evt act <- st  = walkPFSM act (checkPrio evt acc)
  | Await     evt act <- st  = walkPFSM act (checkPrio evt acc)
  | Sequence  ac1 ac2 <- st  = walkPFSM ac1 $ walkPFSM ac2 acc
  | Init      ac1 ac2 <- st  = walkPFSM ac1 $ walkPFSM ac2 acc
  | Alternate ac1 ac2 <- st  = walkPFSM ac1 $ walkPFSM ac2 acc -- both branches need filter defs
  | otherwise                = acc
  where
    checkPrio ev acc' = (mkPrio ev):acc'
    mkPrio ev' = PrioritiseInfo $ \s m -> handleMessage m (resolveEvent ev' m s)

handleRpcRawInputs :: forall s d . (Show s) => State s d
                   -> (P.Message, SendPort P.Message)
                   -> Action (State s d)
handleRpcRawInputs st@State{..} (msg, port) =
  handleInput msg $ st { stReply = (sendChan port), stTrans = Q.empty, stInput = Just msg }

handleAllRawInputs :: forall s d. (Show s) => State s d
                   -> P.Message
                   -> Action (State s d)
handleAllRawInputs st@State{..} msg =
  handleInput msg $ st { stReply = noOp, stTrans = Q.empty, stInput = Just msg }

noOp :: P.Message -> Process ()
noOp = const $ return ()

handleInput :: forall s d . (Show s)
            => P.Message
            -> State s d
            -> Action (State s d)
handleInput msg st@State{..} = do
  res <- apply st msg stProg
  case res of
    Just res' -> applyTransitions res' []
    Nothing   -> continue st
