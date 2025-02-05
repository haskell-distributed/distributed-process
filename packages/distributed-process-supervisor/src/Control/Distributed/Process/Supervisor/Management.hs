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
import Data.Hashable (Hashable(..))
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

-- | Monitor the supervisor for the given pid. Binds a typed channel to the
-- calling process, to which the resulting @ReceivePort@ belongs.
--
-- Multiple monitors can be created for any @calling process <-> sup@ pair.
-- Each monitor maintains its own typed channel, which will only contain
-- "MxSupervisor" entries obtained /after/ the channel was established.
--
monitorSupervisor :: SupervisorPid -> Process (ReceivePort MxSupervisor)
monitorSupervisor sup = do
  us <- getSelfPid
  (sp, rp) <- newChan
  mxNotify $ Register sup us sp
  return rp

-- | Removes all monitors for @sup@, associated with the calling process.
-- It is not possible to delete individual monitors (i.e. typed channels).
--
unmonitorSupervisor :: SupervisorPid -> Process ()
unmonitorSupervisor sup = getSelfPid >>= mxNotify . UnRegister sup

-- | Starts the supervision monitoring agent.
supervisionMonitor :: Process ProcessId
supervisionMonitor = do
  mxAgent supervisionAgentId initState [
        (mxSink $ \(Register sup pid sp) -> do
          mxSetLocal . Map.insert sup (pid, SupMxChan sp) =<< mxGetLocal
          mxReady)
      , (mxSink $ \(UnRegister sup pid) -> do
          st <- mxGetLocal
          mxSetLocal $ Map.filterWithKey (\k v -> if k == sup then (fst v) /= pid else True) st
          mxReady)
      , (mxSink $ \(ev :: MxEvent) -> do
          case ev of
            MxUser msg          -> goNotify msg >> mxReady
            MxProcessDied pid _ -> do st <- mxGetLocal
                                      mxSetLocal $ Map.filter ((/= pid) . fst) st
                                      mxReady
            _                   -> mxReady)
    ]
  where
    initState :: State
    initState = Map.empty

    goNotify msg = do
      ev <- liftMX $ unwrapMessage msg :: MxAgent State (Maybe MxSupervisor)
      case ev of
        Just ev' -> do st <- mxGetLocal
                       mapM_ (liftMX . (flip sendChan) ev' . smxc . snd)
                             (maybe [] id $ Map.lookup (supervisorPid ev') st)
        Nothing  -> return ()
