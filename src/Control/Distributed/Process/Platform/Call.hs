{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Call
-- Copyright   :  (c) Parallel Scientific (Jeff Epstein) 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainers :  Jeff Epstein, Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a facility for Remote Procedure Call (rpc) style
-- interactions with Cloud Haskell processes.
--
-- Clients make synchronous calls to a running process (i.e., server) using the
-- 'callAt', 'callTimeout' and 'multicall' functions. Processes acting as the
-- server are constructed using Cloud Haskell's 'receive' family of primitives
-- and the 'callResponse' family of functions in this module.   
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Call 
  ( -- client API
    callAt
  , callTimeout
  , multicall
    -- server API
  , callResponse
  , callResponseIf
  , callResponseDefer
  , callResponseDeferIf
  , callForward
  , callResponseAsync
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad (forM, forM_, join)
import Data.List (delete)
import qualified Data.Map as M
import Data.Maybe (listToMaybe)
import Data.Binary (Binary,get,put)
import Data.Typeable (Typeable)

import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Time

----------------------------------------------
-- * Multicall
----------------------------------------------

-- | Sends a message of type a to the given process, to be handled by a corresponding
-- callResponse... function, which will send back a message of type b.
-- The tag is per-process unique identifier of the transaction. If the timeout expires
-- or the target process dies, Nothing will be returned.
callTimeout :: (Serializable a, Serializable b) => ProcessId -> a -> Tag -> Timeout -> Process (Maybe b)
callTimeout pid msg tag time = 
  do res <- multicall [pid] msg tag time 
     return $ join (listToMaybe res)

-- | Like 'callTimeout', but with no timeout. Returns Nothing if the target process dies.
callAt :: (Serializable a, Serializable b) => ProcessId -> a -> Tag -> Process (Maybe b)
callAt pid msg tag = callTimeout pid msg tag infiniteWait

-- | Like 'callTimeout', but sends the message to multiple recipients and collects the results.
multicall :: forall a b.(Serializable a, Serializable b) => [ProcessId] -> a -> Tag -> Timeout -> Process [Maybe b]
multicall nodes msg tag time =
  do caller <- getSelfPid
     reciever <- spawnLocal $
         do reciever_pid <- getSelfPid
            mon_caller <- monitor caller
            () <- expect
            monitortags <- forM nodes monitor
            forM_ nodes $ \node -> send node (Multicall, node, reciever_pid, tag, msg)
            maybeTimeout time tag reciever_pid
            results <- recv nodes monitortags mon_caller
            send caller (MulticallResponse,tag,results)
     mon_reciever <- monitor reciever
     send reciever ()
     receiveWait
       [
         matchIf (\(MulticallResponse,mtag,_) -> mtag == tag)
                 (\(MulticallResponse,_,val) -> return val),
         matchIf (\(ProcessMonitorNotification ref _pid reason) -> ref == mon_reciever && reason /= DiedNormal)
                 (\_ -> error "multicall: unexpected termination of worker process")
       ]
   where
         recv nodes' monitortags mon_caller = 
           do 
              let
                  ordered [] _ = []
                  ordered (x:xs) m = 
                      M.lookup x m : ordered xs m
                  recv1 ([],_,results) = return results
                  recv1 (_,[],results) = return results
                  recv1 (nodesleft,monitortagsleft,results) =
                     receiveWait
                         [
                            matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mon_caller)
                                    (\_ -> return Nothing),
                            matchIf (\(ProcessMonitorNotification ref pid reason) -> 
                                        ref `elem` monitortagsleft && pid `elem` nodesleft && reason /= DiedNormal)
                                    (\(ProcessMonitorNotification ref pid _reason) -> 
                                        return $ Just (delete pid nodesleft, delete ref monitortagsleft, results)),
                            matchIf (\(MulticallResponse,mtag,_,_) -> mtag == tag)
                                    (\(MulticallResponse,_,responder,msgx) -> 
                                        return $ Just (delete responder nodesleft, monitortagsleft, M.insert responder (msgx::b) results)),
                            matchIf (\(TimeoutNotification mtag) -> mtag == tag )
                                    (\_ -> return Nothing)
                         ]
                            >>= maybe (return results) recv1
              resultmap <- recv1 (nodes', monitortags, M.empty) :: Process (M.Map ProcessId b)
              return $ ordered nodes' resultmap

data MulticallResponseType a =
         MulticallAccept
       | MulticallForward ProcessId a
       | MulticallReject deriving Eq

callResponseImpl :: (Serializable a,Serializable b) => (a -> MulticallResponseType c) -> 
                         (a -> (b -> Process())-> Process c) -> Match c
callResponseImpl cond proc = 
    matchIf (\(Multicall,_responder,_,_,msg) -> 
                 case cond msg of
                    MulticallReject -> False
                    _ -> True) 
            (\wholemsg@(Multicall,responder,sender,tag,msg) -> 
                 case cond msg of
                   MulticallForward target ret -> -- TODO sender should get a ProcessMonitorNotification if target dies, or we should link target
                     do send target wholemsg
                        return ret
                   MulticallReject -> error "multicallResponseImpl: Indecisive condition"
                   MulticallAccept ->
                     let resultSender tosend = send sender (MulticallResponse,tag::Tag,responder::ProcessId, tosend)
                      in proc msg resultSender)

-- | Produces a Match that can be used with the 'receiveWait' family of message-receiving functions.
-- callResponse will respond to a message of type a sent by 'callTimeout', and will respond with
-- a value of type b.
callResponse :: (Serializable a,Serializable b) => (a -> Process (b,c)) -> Match c
callResponse = 
    callResponseIf (const True)

callResponseDeferIf  :: (Serializable a,Serializable b) => (a -> Bool) -> (a -> (b -> Process())-> Process c) -> Match c
callResponseDeferIf cond = callResponseImpl (\msg -> if cond msg then MulticallAccept else MulticallReject)

callResponseDefer  :: (Serializable a,Serializable b) => (a -> (b -> Process())-> Process c) -> Match c
callResponseDefer = callResponseDeferIf (const True)


-- | Produces a Match that can be used with the 'receiveWait' family of message-receiving functions.
-- When calllForward receives a message of type from from 'callTimeout' (and similar), it will forward
-- the message to another process, who will be responsible for responding to it. It is the user's
-- responsibility to ensure that the forwarding process is linked to the destination process, so that if
-- it fails, the sender will be notified.
callForward :: Serializable a => (a -> (ProcessId, c)) -> Match c
callForward proc = 
   callResponseImpl 
     (\msg -> let (pid, ret) = proc msg
               in MulticallForward pid ret )
     (\_ sender -> (sender::(() -> Process ())) `mention` error "multicallForward: Indecisive condition")

-- | The message handling code is started in a separate thread. It's not automatically
-- linked to the calling thread, so if you want it to be terminated when the message
-- handling thread dies, you'll need to call link yourself.
callResponseAsync :: (Serializable a,Serializable b) => (a -> Maybe c) -> (a -> Process b) -> Match c
callResponseAsync cond proc =
   callResponseImpl 
         (\msg -> 
            case cond msg of
              Nothing -> MulticallReject
              Just _ -> MulticallAccept)
         (\msg sender -> 
            do _ <- spawnLocal $ -- TODO linkOnFailure to spawned procss
                 do val <- proc msg
                    sender val
               case cond msg of
                 Nothing -> error "multicallResponseAsync: Indecisive condition"
                 Just ret -> return ret )  

callResponseIf :: (Serializable a,Serializable b) => (a -> Bool) -> (a -> Process (b,c)) -> Match c
callResponseIf cond proc = 
    callResponseImpl
             (\msg -> 
                 case cond msg of
                   True -> MulticallAccept
                   False -> MulticallReject) 
             (\msg sender -> 
                 do (tosend,toreturn) <- proc msg 
                    sender tosend
                    return toreturn)

maybeTimeout :: Timeout -> Tag -> ProcessId -> Process ()
maybeTimeout Nothing _ _ = return ()
maybeTimeout (Just time) tag p = timeout time tag p

----------------------------------------------
-- * Private types
----------------------------------------------

mention :: a -> b -> b
mention _a b = b

data Multicall = Multicall
       deriving (Typeable)
instance Binary Multicall where
       get = return Multicall
       put _ = return ()
data MulticallResponse = MulticallResponse
       deriving (Typeable)
instance Binary MulticallResponse where
       get = return MulticallResponse
       put _ = return ()

