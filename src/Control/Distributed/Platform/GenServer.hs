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
    ServerId(..),
    defaultServer
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
data ServerId rq rep
  = ServerId String (SendPort (Request rq rep))

instance (Serializable rq, Serializable rep) => Show (ServerId rq rep) where
  show (ServerId serverId sport) = serverId ++ ":" ++ show (sendPortId sport)

-- | Request
newtype Request req reply = Request (SendPort reply, req)
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
      -> Process (ServerId rq rs)
serverStart name createServer = do
    say $ "Starting server " ++ name

    -- spawnChannelLocal :: Serializable a
    --              => (ReceivePort a -> Process ())
    --              -> Process (SendPort a)
    sreq <- spawnChannelLocal $ serverProcess
    return $ ServerId name sreq
  where
    serverProcess rreq = do

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
                tryRequest <- expectTimeout value
                case tryRequest of
                  Just req -> handleRequest server req
                  Nothing -> return ()
              NoTimeout       -> do
                say $ "Waiting for call to " ++ name
                req <- receiveChan rreq -- :: Process (ProcessId, rq)

                handleRequest server req

                return ()

      -- terminate
      handleTerminate server TerminateNormal

    handleRequest server (Request (sreply, rq)) = do
      say $ "Handling call for " ++ name
      callResult <- handleCall server rq
      case callResult of
        CallOk reply -> do
          say $ "Sending reply from " ++ name
          sendChan sreply reply
        CallDeferred ->
          say $ "Not sending reply from " ++ name
        CallStop reason ->
          say $ "Stop: " ++ reason ++ " -- Not implemented!"

-- | Call a process using it's name
-- nsend doesnt seem to support timeouts?
--serverNCall :: (Serializable a, Serializable b) => Name -> a -> Process b
--serverNCall name rq = do
--  (sport, rport) <- newChan
--  nsend name (sport, rq)
--  receiveChan rport
--  --us <- getSelfPid
--  --nsend name (us, rq)
--  --expect

-- | call a process using it's process id
serverCall :: (Serializable rq, Serializable rs) => ServerId rq rs -> rq -> Timeout -> Process rs
serverCall (ServerId _ sreq) rq timeout = do
  (sreply, rreply) <- newChan
  sendChan sreq $ Request (sreply, rq)
  case timeout of
    NoTimeout -> receiveChan rreply
    Timeout value -> do
      maybeMsg <- error "not implemented" -- expectTimeout value
      case maybeMsg of
        Just msg -> return msg
        Nothing -> error $ "timeout! value = " ++ show value

-- | out of band reply to a client
serverReply :: (Serializable a) => SendPort a -> a -> Process ()
serverReply sport reply = do
  sendChan sport reply
