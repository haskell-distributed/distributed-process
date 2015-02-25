{-# LANGUAGE RecursiveDo  #-}
-----------------------------------------------------------------------------
---- |
---- Module      :  Control.Distributed.Process.Node.RegistryAgent
---- Copyright   :  (c) Tweag I/O 2015
---- License     :  BSD3 (see the file LICENSE)
----
---- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
---- Stability   :  experimental
---- Portability :  non-portable (requires concurrency)
----
---- This module provides a registry monitoring agent, implemented as a
---- /distributed-process Management Agent/. Every 'node' starts this agent on
---- startup. The agent will monitor every remote process that was added to the
---- local registry, so the node removes the process from the registry when it
---- dies or when a network failure is detected.
----
-------------------------------------------------------------------------------

module Control.Distributed.Process.Node.RegistryAgent
    ( registryMonitorAgent
    ) where

import Control.Distributed.Process.Management
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Internal.Primitives
import Data.Foldable (forM_)
import Data.Map (Map)
import qualified Data.Map as Map

registryMonitorAgentId :: MxAgentId
registryMonitorAgentId = MxAgentId "service.registry.monitoring"

-- | Registry monitor agent
--
-- This agent listens for 'MxRegistered' and 'MxUnRegistered' events and tracks
-- all remote 'ProcessId's that are stored in the registry.
--
-- When a remote process is registered, the agent starts monitoring it until it
-- is unregistered or the monitor notification arrives.
--
-- The agent keeps the amount of labels associated with each registered remote
-- process. This is necessary so the process is unmonitored only when it has
-- been unregistered from all of the labels.
--
registryMonitorAgent :: Process ProcessId
registryMonitorAgent = do
  nid <- getSelfNode
  -- For each process the map associates the 'MonitorRef' used to monitor it and
  -- the amount of labels associated with it.
  mxAgent registryMonitorAgentId (Map.empty :: Map ProcessId (MonitorRef, Int))
    [ mxSink $ \(ProcessMonitorNotification _ pid _) -> do
        mxUpdateLocal (Map.delete pid)
        mxReady
    , mxSink $ \ev -> do
        case ev of
          MxRegistered pid _
            | processNodeId pid /= nid -> do
            hm <- mxGetLocal
            m <- liftMX $ mdo
              let (v,m) = Map.insertLookupWithKey (\_ (m',r) _ -> (m',r+1))
                                                  pid (mref,1) hm
              mref <- maybe (monitor pid) (return . fst) v
              return m
            mxSetLocal m
          MxUnRegistered pid _
            | processNodeId pid /= nid -> do
            hm <- mxGetLocal
            forM_ (pid `Map.lookup` hm) $ \(mref, i) ->
              let i' = pred i
              in if i' == 0
                 then do liftMX $ unmonitorAsync mref
                         mxSetLocal $! pid `Map.delete` hm
                 else mxSetLocal $ Map.insert pid (mref,i') hm
          _ -> return ()
        mxReady
      -- remove async answers from mailbox
    , mxSink $ \RegisterReply{} -> mxReady
    , mxSink $ \DidUnmonitor{} -> mxReady
    ]
