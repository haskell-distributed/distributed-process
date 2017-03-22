-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.FSM.Client
-- Copyright   :  (c) Tim Watson 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- The Client Portion of the /FSM/ API.
-----------------------------------------------------------------------------
module Control.Distributed.Process.FSM.Client
 ( call
 , callTimeout
 , safeCall
 ) where

import Control.Distributed.Process
 ( send
 , wrapMessage
 , newChan
 , unwrapMessage
 , receiveWait
 , receiveTimeout
 , monitor
 , unmonitor
 , die
 , matchChan
 , matchIf
 , catchesExit
 , handleMessageIf
 , getSelfPid
 , Message
 , Process
 , SendPort
 , ReceivePort
 , ProcessId
 , ProcessMonitorNotification(..)
 )
import Control.Distributed.Process.Extras (ExitReason(ExitOther))
import Control.Distributed.Process.Extras.Time (TimeInterval, asTimeout)
import Control.Distributed.Process.FSM.Internal.Types (baseErr)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.Catch (bracket)

safeCall :: (Serializable m, Serializable r)
         => ProcessId
         -> m
         -> Process (Either ExitReason r)
safeCall pid msg = do
  us <- getSelfPid
  (call pid msg >>= return . Right)
    `catchesExit` [(\sid rsn -> handleMessageIf rsn (weFailed sid us)
                                                    (return . Left))]
  where
    weFailed a b (ExitOther _) = a == b
    weFailed _ _ _             = False

callTimeout :: (Serializable m, Serializable r)
            => ProcessId
            -> m
            -> TimeInterval
            -> Process (Maybe r)
callTimeout pid msg ti = bracket (monitor pid) unmonitor $ \mRef -> do
  (sp, rp) <- newChan :: Process (SendPort Message, ReceivePort Message)
  send pid (wrapMessage msg, sp)
  msg' <- receiveTimeout (asTimeout ti)
                         [ matchChan rp return
                         , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                                   (\_ -> die $ ExitOther "ServerUnreachable")
                         ] :: Process (Maybe Message)
  case msg' of
    Nothing -> return Nothing
    Just m  -> do mR <- unwrapMessage m
                  case mR of
                    Just r -> return $ Just r
                    _      -> die $ ExitOther $ baseErr ++ ".Client:InvalidResponseType"

call :: (Serializable m, Serializable r) => ProcessId -> m -> Process r
call pid msg = bracket (monitor pid) unmonitor $ \mRef -> do
  (sp, rp) <- newChan :: Process (SendPort Message, ReceivePort Message)
  send pid (wrapMessage msg, sp)
  msg' <- receiveWait [ matchChan rp return
                      , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                                (\(ProcessMonitorNotification _ _ r) -> die $ ExitOther (show r))
                      ] :: Process Message
  mR <- unwrapMessage msg'
  case mR of
    Just r -> return r
    _      -> die $ ExitOther $ baseErr ++ ".Client:InvalidResponseType"
