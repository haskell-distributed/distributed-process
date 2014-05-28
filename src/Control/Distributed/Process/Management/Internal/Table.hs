{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RankNTypes  #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE RecordWildCards #-}

module Control.Distributed.Process.Management.Internal.Table
  ( MxTableRequest(..)
  , MxTableId(..)
  , mxTableCoordinator
  , startTableCoordinator
  , delete
  , purge
  , clear
  , set
  , get
  , fetch
  ) where

import Control.Distributed.Process.Internal.Primitives
  ( receiveWait
  , receiveChan
  , match
  , matchAny
  , matchIf
  , matchChan
  , send
  , nsend
  , sendChan
  , getSelfPid
  , link
  , monitor
  , unwrapMessage
  , newChan
  , withMonitor
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , ProcessMonitorNotification(..)
  , SendPort
  , ReceivePort
  , Message
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Management.Internal.Types
  ( MxTableId(..)
  , MxAgentId(..)
  , MxAgentStart(..)
  , Fork)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.IO.Class (liftIO)
import Data.Accessor (Accessor, accessor, (^=), (^:))
import Data.Binary (Binary)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Typeable (Typeable)

import GHC.Generics

-- An extremely lightweight shared Map implementation, for use
-- by /management agents/ and their cohorts. Each agent is assigned
-- a table, into which any serializable @Message@ can be inserted.
-- Data are inserted, removed and searched for via their key, which
-- is a string. Tables can be purged, values can be set, fetched or
-- cleared/removed.
--

data MxTableRequest =
    Delete
  | Purge
  | Clear !String
  | Set !String !Message
  | Get !String !(SendPort (Maybe Message)) -- see [note: un-typed send port]
  deriving (Typeable, Generic)
instance Binary MxTableRequest where

data MxTableState = MxTableState { _name    :: !String
                                 , _entries :: !(Map String Message)
                                 }

type MxTables = Map MxAgentId ProcessId

mxTableCoordinator :: String
mxTableCoordinator = "mx.table.coordinator"

delete :: MxTableId -> Process ()
delete = sendReq Delete

purge :: MxTableId -> Process ()
purge = sendReq Purge

clear :: String -> MxTableId -> Process ()
clear k = sendReq (Clear k)

set :: String -> Message -> MxTableId -> Process ()
set k v = sendReq (Set k v)

fetch :: forall a. (Serializable a)
      => MxTableId
      -> String
      -> Process (Maybe a)
fetch (MxForPid pid)      key = get pid key
fetch mxId@(MxForAgent _) key = do
  (sp, rp) <- newChan :: Process (SendPort (Maybe Message),
                                  ReceivePort (Maybe Message))
  sendReq (Get key sp) mxId
  receiveChan rp >>= maybe (return Nothing)
                           (unwrapMessage :: Message -> Process (Maybe a))

-- [note: un-typed send port]
-- Here, fetch uses a typed channel over a raw Message to obtain
-- its result, so type checking is deferred until receipt and will
-- be handled in the caller's thread. This is necessary because
-- the server portion of the code knows nothing about the types
-- involved, nor should it, since these tables can be used to
-- store arbitrary serializable data.

get :: forall a. (Serializable a)
      => ProcessId
      -> String
      -> Process (Maybe a)
get pid key = do
  safeFetch pid key >>= maybe (return Nothing)
                              (unwrapMessage :: Message -> Process (Maybe a))

safeFetch :: ProcessId -> String -> Process (Maybe Message)
safeFetch pid key = do
  (sp, rp) <- newChan
  send pid $ Get key sp
  withMonitor pid $ do
    receiveWait [
        matchChan rp return
      , matchIf (\(ProcessMonitorNotification _ pid' _) -> pid' == pid)
                (\_ -> return $ Just (unsafeCreateUnencodedMessage ()))
      ]

sendReq :: MxTableRequest -> MxTableId -> Process ()
sendReq req tid = (resolve tid) req

resolve :: Serializable a => MxTableId -> (a -> Process ())
resolve (MxForAgent agent) = \msg -> nsend mxTableCoordinator (agent, msg)
resolve (MxForPid   pid)   = \msg -> send pid msg

startTableCoordinator :: Fork -> Process ()
startTableCoordinator fork = run Map.empty
  where
    run :: MxTables -> Process ()
    run tables =
      receiveWait [
          -- note that this state change can race with MxAgentStart requests
          match (\(ProcessMonitorNotification _ pid _) -> do
                    return $ Map.filter (/= pid) tables)
        , match (\(MxAgentStart ch agent) -> do
                    lookupAgent tables agent >>= \(p, t) -> do
                    sendChan ch p >> return t)
        , match (\req@(agent, tReq :: MxTableRequest) -> do
                    case tReq of
                      Get k sp -> do
                        lookupAgent tables agent >>= \(p, t) -> do
                            safeFetch p k >>= sendChan sp >> return t
                      _ -> do
                        handleRequest tables req)
        , matchAny (\_ -> return tables) -- unrecognised messages are dropped
        ] >>= run

    handleRequest :: MxTables
                  -> (MxAgentId, MxTableRequest)
                  -> Process MxTables
    handleRequest tables' (agent, req) = do
      lookupAgent tables' agent >>= \(p, t) -> send p req >> return t

    lookupAgent :: MxTables -> MxAgentId -> Process (ProcessId, MxTables)
    lookupAgent tables' agentId' = do
      case Map.lookup agentId' tables' of
        Nothing -> launchNew agentId' tables'
        Just p  -> return (p, tables')

    launchNew :: MxAgentId
              -> MxTables
              -> Process (ProcessId, MxTables)
    launchNew mxId tblMap = do
      let initState = MxTableState { _name = (agentId mxId)
                                   , _entries = Map.empty
                                   }
      (pid, _) <- spawnSup $ tableHandler initState
      return $ (pid, mxId `seq` pid `seq` Map.insert mxId pid tblMap)

    spawnSup proc = do
      us   <- getSelfPid
      -- we need to use that passed in "fork", in order to
      -- break an import cycle with Node.hs courtesy of the
      -- management agent, API and tracing modules
      them <- liftIO $ fork $ link us >> proc
      ref  <- monitor them
      return (them, ref)

tableHandler :: MxTableState -> Process ()
tableHandler state = do
  ns <- receiveWait [
      match (handleTableRequest state)
    , matchAny (\_ -> return (Just state))
    ]
  case ns of
    Nothing -> return ()
    Just s' -> tableHandler s'
  where
    handleTableRequest _  Delete    = return Nothing
    handleTableRequest st Purge     = return $ Just $ (entries ^= Map.empty) $ st
    handleTableRequest st (Clear k) = return $ Just $ (entries ^: (k `seq` Map.delete k)) $ st
    handleTableRequest st (Set k v) = return $ Just $ (entries ^: (k `seq` v `seq` Map.insert k v)) st
    handleTableRequest st (Get k c) = getEntry k c st >> return (Just st)

getEntry :: String
         -> SendPort (Maybe Message)
         -> MxTableState
         -> Process ()
getEntry k m MxTableState{..} = do
  sendChan m =<< return (Map.lookup k _entries)

entries :: Accessor MxTableState (Map String Message)
entries = accessor _entries (\ls st -> st { _entries = ls })
