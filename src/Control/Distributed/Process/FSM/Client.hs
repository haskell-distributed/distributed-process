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
 , receiveChan
 , monitor
 , unmonitor
 , die
 , matchChan
 , matchIf
 , Message
 , Process
 , SendPort
 , ReceivePort
 , ProcessId
 , ProcessMonitorNotification(..)
 , MonitorRef
 )
import Control.Distributed.Process.Extras (ExitReason(ExitOther))
import Control.Distributed.Process.FSM.Internal.Types (baseErr)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.Catch (bracket)

call :: (Serializable m, Serializable r) => ProcessId -> m -> Process r
call pid msg = bracket (monitor pid) unmonitor $ \mRef -> do
  (sp, rp) <- newChan :: Process (SendPort Message, ReceivePort Message)
  send pid (wrapMessage msg, sp)
  msg <- receiveWait [ matchChan rp return
                     , matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mRef)
                               (\_ -> die $ ExitOther "ServerUnreachable")
                     ] :: Process Message
  mR <- unwrapMessage msg
  case mR of
    Just r -> return r
    _      -> die $ ExitOther $ baseErr ++ ".Client:InvalidResponseType"
