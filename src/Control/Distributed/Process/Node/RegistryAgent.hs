{-# LANGUAGE BangPatterns #-}
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
---- This module provides registry monitoring agent, implemented as
---- a /distributed-process Management Agent/. Once 'node' starts it run this
---- agent, such agent will monitor every remove process that is added to node
---- and remove Processes from registry if they die.
----
-------------------------------------------------------------------------------

module Control.Distributed.Process.Node.RegistryAgent
    ( registryMonitorAgent
    ) where

import Control.Distributed.Process.Management
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Internal.Primitives
import Data.Foldable (forM_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

registryMonitorAgentId :: MxAgentId
registryMonitorAgentId = MxAgentId "service.registry.monitoring"

registryMonitorAgent :: Process ProcessId
registryMonitorAgent = do
    mxAgent registryMonitorAgentId initState
        [ mxSink $ \(ProcessMonitorNotification _ pid _) -> do
            mxUpdateLocal (Map.delete pid)
            mxReady
        , mxSink $ \ev ->
            let act = case ev of
                    MxRegistered pid _ -> do
                        hm <- mxGetLocal
                        case pid `Map.lookup` hm of
                            Nothing -> do
                                mon <- liftMX $ monitor pid
                                mxUpdateLocal (Map.insert pid (mon, 1))
                            Just _  -> return ()
                    MxUnRegistered pid _ -> do
                        hm <- mxGetLocal
                        forM_ (pid `Map.lookup` hm) $ \(mref, i) ->
                           let !i' = succ i  
                           in if i' == 0
                              then do liftMX $ unmonitorAsync mref
                                      mxSetLocal $! pid `Map.delete` hm
                              else mxSetLocal $ Map.insert pid (mref,i') hm
                    _ -> return ()
            in act >> mxReady
          -- remove async answers from mailbox
        , mxSink $ \RegisterReply{} -> mxReady
        , mxSink $ \DidUnmonitor{} -> mxReady
        ]
    where
        initState :: Map ProcessId (MonitorRef,Int)
        initState = Map.empty
