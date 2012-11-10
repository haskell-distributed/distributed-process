{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeFamilies              #-}

module Control.Distributed.Platform.GenServer (
    Name,
    Timeout(..),
    InitResult(..),
    CallResult(..),
    CastResult(..),
    Info(..),
    InfoResult(..),
    TerminateReason(..),
    Request(..),
    Reply(..),
    serverStart,
    --serverNCall,
    serverCall,
    serverReply,
    Server(..),
    ServerId,    defaultServer
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad                            (forever)
import           Data.Typeable                            (Typeable)
import           Prelude                                  hiding (catch, init)

import           Data.Binary                              (Binary (..))
import           Data.DeriveTH

--------------------------------------------------------------------------------
-- Data Types                                                                 --
--------------------------------------------------------------------------------
data InitResult
  = InitOk Timeout
  | InitStop String
  | InitIgnore

data CallResult r
  = CallOk r
  | CallStop String
  | CallDeferred

data CastResult
  = CastOk
  | CastStop String

data Info
  = InfoTimeout Timeout
  | Info String

data InfoResult
  = InfoNoReply Timeout
  | InfoStop String

data TerminateReason
  = TerminateNormal
  | TerminateShutdown
  | TerminateReason

-- | Server record of callbacks
data Server rq rs = Server {
    handleInit      :: Process InitResult,                  -- ^ initialization callback
    handleCall      :: rq -> Process (CallResult rs),       -- ^ call callback
    handleCast      :: rq -> Process CastResult,            -- ^ cast callback
    handleInfo      :: Info -> Process InfoResult,          -- ^ info callback
    handleTerminate :: TerminateReason -> Process ()        -- ^ termination callback
  }

-- | Default record
-- Starting point for creating new servers
defaultServer :: Server rq rs
defaultServer = Server {
  handleInit = return $ InitOk NoTimeout,
  handleCall = undefined,
  handleCast = \_ -> return $ CastOk,
  handleInfo = \_ -> return $ InfoNoReply NoTimeout,
  handleTerminate = \_ -> return ()
}

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Process name
type Name = String

-- | Process name
data Timeout = Timeout Int
             | NoTimeout

-- | Typed server Id
type ServerId = ProcessId

-- | Request
newtype Request req reply = Request (reply, req)
  deriving (Typeable, Show)

$(derive makeBinary ''Request)

-- | Reply
newtype Reply reply = Reply reply
  deriving (Typeable, Show)

$(derive makeBinary ''Reply)

-- | Start server
--
serverStart :: (Serializable rq, Serializable rs)
      => Name
      -> Process (Server rq rs)
      -> Process ServerId
serverStart name createServer = do
  spawnLocal $ serverProcess
  where
    serverProcess= do
      -- server process
      server <- createServer

      -- init
      say $ "Initializing " ++ name
      initResult <- handleInit server
      case initResult of
        InitIgnore -> do
          return () -- ???
        InitStop reason -> do
          say $ "Initialization stopped: " ++ reason
          return ()
        InitOk timeout -> do

          -- loop
          forever $ do
            case timeout of
              Timeout value -> do
                say $ "Waiting for call to " ++ name ++ " with timeout " ++ show value
                maybeReq <- expectTimeout value
                case maybeReq of
                  Just req -> handleRequest server req
                  Nothing -> return ()
              NoTimeout       -> do
                say $ "Waiting for call to " ++ name
                req <- expect

                handleRequest server req

                return ()

      -- terminate
      handleTerminate server TerminateNormal

    handleRequest server (Request (cid, rq)) = do
      say $ "Handling call for " ++ name
      callResult <- handleCall server rq
      case callResult of
        CallOk reply -> do
          say $ "Sending reply from " ++ name
          send cid reply
        CallDeferred ->
          say $ "Not sending reply from " ++ name
        CallStop reason ->
          say $ "Stop: " ++ reason ++ " -- Not implemented!"

-- | call a process using it's process id
serverCall :: (Serializable rq, Serializable rs) => ServerId -> rq -> Timeout -> Process rs
serverCall sid rq timeout = do
  cid <- getSelfPid
  send sid $ Request (cid, rq)
  case timeout of
    NoTimeout -> expect
    Timeout value -> do
      maybeReply <- expectTimeout value
      case maybeReply of
        Just msg -> return msg
        Nothing -> error $ "timeout! value = " ++ show value

-- | out of band reply to a client
serverReply :: (Serializable a) => ServerId -> a -> Process ()
serverReply sid reply = do
  send sid reply
