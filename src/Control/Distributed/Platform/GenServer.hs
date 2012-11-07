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
    serverStart,
    serverNCall,
    serverCall,
    serverReply,
    Server(..),
    defaultServer
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Monad                            (forever)
import           Prelude                                  hiding (catch, init)

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
    handleInit      :: Process InitResult,                 -- ^ initialization callback
    handleCall      :: rq -> Process (Maybe rs),           -- ^ call callback
    handleCast      :: rq -> Process (),                   -- ^ cast callback
    handleInfo      :: Info -> Process InfoResult,         -- ^ info callback
    handleTerminate :: TerminateReason -> Process ()  -- ^ termination callback
  }

defaultServer :: Server rq rs
defaultServer = Server {
  handleInit = return $ InitOk NoTimeout,
  handleCall = \_ -> return Nothing,
  handleCast = \_ -> return (),
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

-- | Start server
--
serverStart :: (Serializable rq, Serializable rs)
      => Name
      -> Process (Server rq rs)
      -> Process ProcessId
serverStart name createServer = do
    say $ "Starting server " ++ name
    from <- getSelfPid
    server <- createServer
    pid <- spawnLocal $ do
      say $ "Initializing " ++ name
      initResult <- handleInit server
      case initResult of
        InitIgnore -> do
          return ()
        InitStop reason -> do
          say $ "Initialization stopped: " ++ reason
          return ()
        InitOk timeout -> do
          send from () -- let them know we are ready
          forever $ do
            case timeout of
              Timeout value -> do
                say $ "Waiting for call to " ++ name ++ " with timeout " ++ show value
                maybeMsg <- expectTimeout value
                case maybeMsg of
                  Just msg -> handle server msg
                  Nothing -> return ()
              NoTimeout       -> do
                say $ "Waiting for call to " ++ name
                msg <- expect  -- :: Process (ProcessId, rq)
                --msg <- receiveWait [ matchAny return ]
                handle server msg
                return ()
    say $ "Waiting for " ++ name ++ " to start"
    expect :: Process ()
    say $ "Process " ++ name ++ " initialized"
    register name pid
    return pid
  where
    handle :: (Serializable rs) => Server rq rs -> (ProcessId, rq) -> Process ()
    handle server (them, rq) = do
      say $ "Handling call for " ++ name
      maybeReply <- handleCall server rq
      case maybeReply of
        Just reply -> do
          say $ "Sending reply from " ++ name
          send them reply
        Nothing -> do
          say $ "Not sending reply from " ++ name
          return ()

-- | Call a process using it's name
-- nsend doesnt seem to support timeouts?
serverNCall :: (Serializable a, Serializable b) => Name -> a -> Process b
serverNCall name rq = do
  us <- getSelfPid
  nsend name (us, rq)
  expect

-- | call a process using it's process id
serverCall :: (Serializable a, Serializable b) => ProcessId -> a -> Timeout -> Process b
serverCall to rq timeout = do
  from <- getSelfPid
  send to (from, rq)
  case timeout of
    Timeout value -> do
      maybeMsg <- expectTimeout value
      case maybeMsg of
        Just msg -> return msg
        Nothing -> error "timeout!"
    NoTimeout -> expect

-- | out of band reply to a client
serverReply :: (Serializable a) => ProcessId -> a -> Process ()
serverReply pid reply = do
  send pid reply
