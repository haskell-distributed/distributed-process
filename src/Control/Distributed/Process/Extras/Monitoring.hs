{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Extras.Monitoring
-- Copyright   :  (c) Tim Watson 2013 - 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a primitive node monitoring capability, implemented as
-- a /distributed-process Management Agent/. Once the 'nodeMonitor' agent is
-- started, calling 'monitorNodes' will ensure that whenever the local node
-- detects a new network-transport connection (from another cloud haskell node),
-- the caller will receive a 'NodeUp' message in its mailbox. If a node
-- disconnects, a corollary 'NodeDown' message will be delivered as well.
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Extras.Monitoring
  (
    NodeUp(..)
  , NodeDown(..)
  , nodeMonitorAgentId
  , nodeMonitor
  , monitorNodes
  , unmonitorNodes
  ) where

import Control.DeepSeq (NFData)
import Control.Distributed.Process  -- NB: requires NodeId(..) to be exported!
import Control.Distributed.Process.Management
  ( MxEvent(MxConnected, MxDisconnected)
  , MxAgentId(..)
  , mxAgent
  , mxSink
  , mxReady
  , liftMX
  , mxGetLocal
  , mxSetLocal
  , mxNotify
  )
import Control.Distributed.Process.Extras (deliver)
import Data.Binary
import qualified Data.Foldable as Foldable
import Data.HashSet (HashSet)
import qualified Data.HashSet as Set

import Data.Typeable (Typeable)
import GHC.Generics

data Register = Register !ProcessId
  deriving (Typeable, Generic)
instance Binary Register where
instance NFData Register where

data UnRegister = UnRegister !ProcessId
  deriving (Typeable, Generic)
instance Binary UnRegister where
instance NFData UnRegister where

-- | Sent to subscribing processes when a connection
-- (from a remote node) is detected.
--
data NodeUp = NodeUp !NodeId
  deriving (Typeable, Generic, Show)
instance Binary NodeUp where
instance NFData NodeUp where

-- | Sent to subscribing processes when a dis-connection
-- (from a remote node) is detected.
--
data NodeDown = NodeDown !NodeId
  deriving (Typeable, Generic, Show)
instance Binary NodeDown where
instance NFData NodeDown where

-- | The @MxAgentId@ for the node monitoring agent.
nodeMonitorAgentId :: MxAgentId
nodeMonitorAgentId = MxAgentId "service.monitoring.nodes"

-- | Start monitoring node connection/disconnection events. When a
-- connection event occurs, the calling process will receive a message
-- @NodeUp NodeId@ in its mailbox. When a disconnect occurs, the
-- corollary @NodeDown NodeId@ message will be delivered instead.
--
-- No guaranatee is made about the timeliness of the delivery, nor can
-- the receiver expect that the node (for which it is being notified)
-- is still up/connected or down/disconnected at the point when it receives
-- a message from the node monitoring agent.
--
monitorNodes :: Process ()
monitorNodes = do
  us <- getSelfPid
  mxNotify $ Register us

-- | Stop monitoring node connection/disconnection events. This does not
-- flush the caller's mailbox, nor does it guarantee that any/all node
-- up/down notifications will have been delivered before it is evaluated.
--
unmonitorNodes :: Process ()
unmonitorNodes = do
  us <- getSelfPid
  mxNotify $ UnRegister us

-- | Starts the node monitoring agent. No call to @monitorNodes@ and
-- @unmonitorNodes@ will have any effect unless the agent is already
-- running. Note that we make /no guarantees what-so-ever/ about the
-- timeliness or ordering semantics of node monitoring notifications.
--
nodeMonitor :: Process ProcessId
nodeMonitor = do
  mxAgent nodeMonitorAgentId initState [
        (mxSink $ \(Register pid) -> do
            mxSetLocal . Set.insert pid =<< mxGetLocal
            mxReady)
      , (mxSink $ \(UnRegister pid) -> do
            mxSetLocal . Set.delete pid =<< mxGetLocal
            mxReady)
      , (mxSink $ \ev -> do
            let act =
                  case ev of
                    (MxConnected    _ ep) -> notify $ nodeUp ep
                    (MxDisconnected _ ep) -> notify $ nodeDown ep
                    _                     -> return ()
            act >> mxReady)
    ]
  where
    initState :: HashSet ProcessId
    initState = Set.empty

    notify msg = Foldable.mapM_ (liftMX . deliver msg) =<< mxGetLocal

    nodeUp = NodeUp . NodeId
    nodeDown = NodeDown . NodeId

