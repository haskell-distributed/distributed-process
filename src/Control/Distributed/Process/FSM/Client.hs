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

module Control.Distributed.Process.FSM.Client
where

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
                                (\_ -> die $ ExitOther "ServerUnreachable")
                      ] :: Process Message
  mR <- unwrapMessage msg'
  case mR of
    Just r -> return r
    _      -> die $ ExitOther $ baseErr ++ ".Client:InvalidResponseType"
