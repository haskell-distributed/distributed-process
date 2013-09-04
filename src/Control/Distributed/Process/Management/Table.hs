{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE RecordWildCards #-}

module Control.Distributed.Process.Management.Table
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
import Control.Distributed.Process.Management.Types
  ( MxTableId(..)
  , MxAgentId(..)
  , MxAgentStart(..)
  , Fork)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.IO.Class (liftIO)
import Data.Accessor (Accessor, accessor, (^=), (^:))
import Data.Binary (Binary)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
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

data MxTableState = MxTableState
                    {
                      _name    :: !String
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

    -- TODO: rethink this design. routing via the
    -- coordinator will be a publishing bottle neck,
    -- plus the code in 'fetch' really requires a
    -- pid to send to, so that'll not work via an
    -- intermediary anyway

    run :: MxTables -> Process ()
    run tables =
      receiveWait [
          match (\(MxAgentStart ch agent) ->
                  lookupAgent tables agent >>= \(p, t) -> do
                    sendChan ch p >> return t)
        , match (\(agent, Get k sp) -> do
                    lookupAgent tables agent >>= \(p, t) -> do
                      safeFetch p k >>= sendChan sp >> return t)
        , match $ handleRequest tables
        ] >>= run

    handleRequest :: MxTables
                  -> (MxAgentId, MxTableRequest)
                  -> Process MxTables
    handleRequest tables' (agent, req) =
      lookupAgent tables' agent >>= \(p, t) -> do send p req >> return t

    lookupAgent :: MxTables -> MxAgentId -> Process (ProcessId, MxTables)
    lookupAgent tables' agentId' =
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
      return $ (pid, Map.insert mxId pid tblMap)

    spawnSup proc = do
      us   <- getSelfPid
      -- we need to used that passed in "fork", in order to
      -- break an import cycle with Node.hs via the management
      -- agent, management API and the tracing modules
      them <- liftIO $ fork $ link us >> proc
      -- them <- spawnLocal nid $ link us >> proc
      ref  <- monitor them
      return (them, ref)

tableHandler :: MxTableState -> Process ()
tableHandler state = do
  ns <- receiveWait [
      match (\Delete    -> return Nothing)
    , match (\Purge     -> return $ Just $ (entries ^= Map.empty) $ state)
    , match (\(Clear k) -> return $ Just $ (entries ^: Map.delete k) $ state)
    , match (\(Set k v) -> return $ Just $ (entries ^: Map.insert k v) state)
    , match (\(Get k c) -> getEntry k c state >> return (Just state))
    ]
  case ns of
    Nothing -> return ()
    Just s' -> tableHandler s'

getEntry :: String
         -> SendPort (Maybe Message)
         -> MxTableState
         -> Process ()
getEntry k m MxTableState{..} = sendChan m =<< return (Map.lookup k _entries)

entries :: Accessor MxTableState (Map String Message)
entries = accessor _entries (\ls st -> st { _entries = ls })

