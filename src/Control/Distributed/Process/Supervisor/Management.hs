{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances   #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Supervisor.Management
-- Copyright   :  (c) Tim Watson 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Supervisor.Management
  ( supervisionAgentId
  , supervisionMonitor
  , monitorSupervisor
  , unmonitorSupervisor
    -- * Mx Event Type
  , MxSupervisor(..)
  )
where
import Control.DeepSeq (NFData)
import Control.Distributed.Process
  ( ProcessId
  , Process()
  , ReceivePort()
  , newChan
  , sendChan
  , liftIO
  , say
  , getSelfPid
  , unwrapMessage
  )
import Control.Distributed.Process.Internal.Types (SendPort(..))
import Control.Distributed.Process.Management
  ( MxAgentId(..)
  , MxAgent()
  , MxEvent(MxProcessDied, MxUser)
  , mxAgent
  , mxSink
  , mxReady
  , liftMX
  , mxGetLocal
  , mxSetLocal
  , mxNotify
  )
import Control.Distributed.Process.Supervisor.Types
  ( MxSupervisor(..)
  , SupervisorPid
  )
import Data.Binary
import Data.Foldable (mapM_)
import Data.Hashable (Hashable(..))
import Data.Traversable (traverse)
import Control.Distributed.Process.Extras.Internal.Containers.MultiMap (MultiMap)
import qualified Control.Distributed.Process.Extras.Internal.Containers.MultiMap as Map

import Data.Typeable (Typeable)
import GHC.Generics

data Register = Register !SupervisorPid !ProcessId !(SendPort MxSupervisor)
  deriving (Typeable, Generic)
instance Binary Register where
instance NFData Register where

data UnRegister = UnRegister !SupervisorPid !ProcessId
  deriving (Typeable, Generic)
instance Binary UnRegister where
instance NFData UnRegister where

newtype SupMxChan = SupMxChan { smxc :: SendPort MxSupervisor }
  deriving (Typeable, Generic, Show)
instance Binary SupMxChan
instance NFData SupMxChan
instance Hashable SupMxChan where
  hashWithSalt salt sp = hashWithSalt salt $ sendPortId (smxc sp)
instance Eq SupMxChan where
  (==) a b = (sendPortId $ smxc a) == (sendPortId $ smxc b)

type State = MultiMap SupervisorPid (ProcessId, SupMxChan)

-- | The @MxAgentId@ for the node monitoring agent.
supervisionAgentId :: MxAgentId
supervisionAgentId = MxAgentId "service.monitoring.supervision"

monitorSupervisor :: SupervisorPid -> Process (ReceivePort MxSupervisor)
monitorSupervisor sup = do
  us <- getSelfPid
  (sp, rp) <- newChan
  mxNotify $ Register sup us sp
  return rp

unmonitorSupervisor :: SupervisorPid -> Process ()
unmonitorSupervisor sup = getSelfPid >>= mxNotify . UnRegister sup

supervisionMonitor :: Process ProcessId
supervisionMonitor = do
  mxAgent supervisionAgentId initState [
        (mxSink $ \(Register sup pid sp) -> do
          -- liftMX $ say $ "registering " ++ (show (sup, pid, sp))
          mxSetLocal . Map.insert sup (pid, SupMxChan sp) =<< mxGetLocal
          mxReady)
      , (mxSink $ \(UnRegister sup pid) -> do
          -- liftMX $ say $ "unregistering " ++ (show (sup, pid))
          st <- mxGetLocal
          mxSetLocal $ Map.filterWithKey (\k v -> if k == sup then (fst v) /= pid else True) st
          mxReady)
      {- , (mxSink $ \(ev :: MxEvent) -> do
          case ev of
            MxProcessDied
            TODO: remove dead clients to avoid a space leak
      -}
      , (mxSink $ \(ev :: MxEvent) -> do
          case ev of
            MxUser msg -> goNotify msg >> mxReady
            _          -> mxReady)
    ]
  where
    initState :: State
    initState = Map.empty

    goNotify msg = do
      ev <- liftMX $ unwrapMessage msg :: MxAgent State (Maybe MxSupervisor)
      case ev of
        Just ev' -> do st <- mxGetLocal
                       let cs = Map.lookup (supervisorPid ev') st
                       mapM_ (liftMX . (flip sendChan) ev' . smxc . snd)
                             (maybe [] id $ Map.lookup (supervisorPid ev') st)
