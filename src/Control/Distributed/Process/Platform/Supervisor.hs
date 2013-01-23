{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}

module Control.Distributed.Process.Platform.Supervisor
  ( SupervisorStats(..)
  , ChildId
  , Child(..)
  , ChildKey
  , ChildType
  , ChildSpec
  , toPid
  , start
  , statistics
  , addChild
  , lookupChild
  ) where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Platform.GenProcess hiding (start)
import qualified Control.Distributed.Process.Platform.GenProcess as Server
import Control.Distributed.Process.Platform.Time

import Data.Binary
import Data.DeriveTH
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import Prelude hiding (init)

{-
-export([start_link/2,start_link/3,
     start_child/2, restart_child/2,
     delete_child/2, terminate_child/2,
     which_children/1, find_child/2,
     check_childspecs/1]).
-}

--------------------------------------------------------------------------------
-- Cloud Haskell Generic Supervisor API                                       --
--------------------------------------------------------------------------------

-- TODO: we need process id *and* monitor refs, plus all the startup info

-- type SupervisorRef = ServerId

type ChildId = Int

newtype Child = Child ProcessId
    deriving (Eq, Show, Typeable)
$(derive makeBinary ''Child)

data ChildKey = ChildKey !ChildId !Child
    deriving (Typeable, Show)
$(derive makeBinary ''ChildKey)

instance Eq ChildKey where
  (ChildKey x _) == (ChildKey y _) = x == y

instance Ord ChildKey where
  (ChildKey x _) `compare` (ChildKey y _) = x `compare` y

data ChildType = Worker | Supervisor
    deriving (Typeable, Show, Eq)
$(derive makeBinary ''ChildType)

data ChildSpec = ChildSpec {
    childId   :: ChildKey
  , childType :: ChildType
  } deriving (Typeable, Show, Eq)
$(derive makeBinary ''ChildSpec)

data SupervisorStats = SupervisorStats {
    childSpecCount :: Int
  , childSupervisorCount :: Int
  , childWorkerCount :: Int
  , activeChildCount :: Int
  , activeSupervisorCount :: Int
  , activeWorkerCount :: Int
  -- TODO: usage/restart/freq stats
  , totalRestarts :: Int
  } deriving (Typeable, Show)
$(derive makeBinary ''SupervisorStats)

-- service API types

data ApiCallFind = ApiCallFind ChildKey
    deriving (Typeable, Show, Eq)
$(derive makeBinary ''ApiCallFind)

data ApiCallAdd = ApiCallAdd ChildSpec
    deriving (Typeable, Show, Eq)
$(derive makeBinary ''ApiCallAdd)

data ApiCallStats = ApiCallStats
    deriving (Typeable, Show, Eq)
$(derive makeBinary ''ApiCallStats)

-- supervisor state

-- | Supervisor's state - most of our lookups are id based
data State = State {
    specs  :: Map.Map ChildKey ChildSpec
  , active :: Map.Map ProcessId ChildId
  , stats  :: SupervisorStats
  , maxId  :: Int   -- TODO: use Map.findMax instead...
  }

-- start/specify

start :: Process ProcessId
start =
  let srv = supServer
  in spawnLocal $ Server.start () supInit srv >> return ()

-- client API

toPid :: ChildKey -> ProcessId
toPid (ChildKey _ (Child p)) = p

statistics :: ProcessId -> Process (Maybe SupervisorStats)
statistics = (flip tryCall) ApiCallStats

lookupChild :: ProcessId -> ChildKey -> Process (Maybe ChildSpec)
lookupChild sid = tryCall sid . Just . ApiCallFind

addChild :: ProcessId -> ChildSpec -> Process (Maybe ChildKey)
addChild sid = tryCall sid . Just . ApiCallAdd

-- callback API

handleLookupChild :: State
                  -> ApiCallFind
                  -> Process (ProcessReply State (Maybe ChildSpec))
handleLookupChild state (ApiCallFind key) = reply (spec state key) state
  where spec :: State -> ChildKey -> Maybe ChildSpec
        spec s k = Map.lookup k (specs s)

handleAddChild :: State
               -> ApiCallAdd
               -> Process (ProcessReply State (Maybe ChildKey))
handleAddChild state (ApiCallAdd spec) =
  let childId' = nextId state
      key      = ChildKey childId' emptyChildPid
      spec'    = spec{ childId = key }
  in store key spec' state >>= reply (Just key)

--  child <- tryStartChild state spec
--  case child of
--    err@(Left _) -> reply Nothing state
--    Right key -> markActive key spec state >>= reply (Just key)

handleGetStats :: State
                  -> ApiCallStats
                  -> Process (ProcessReply State SupervisorStats)
handleGetStats s ApiCallStats = reply (stats s) s

-- info APIs

handleMonitorSignal :: State
                    -> ProcessMonitorNotification
                    -> Process (ProcessAction State)
handleMonitorSignal state (ProcessMonitorNotification _ pid _reason) =
  let m = active state
      (cId, active') = Map.updateLookupWithKey (\_ _ -> Nothing) pid m
  in handleChildDown cId active' state

-- internal/aux APIs

handleChildDown :: Maybe ChildId
                -> Map.Map ProcessId ChildId
                -> State
                -> Process (ProcessAction State)
handleChildDown cId active' state =
  let cSpec = case cId of
                Nothing -> undefined :: Maybe ChildSpec
                Just c  -> Map.lookup (initKey c) (specs state)
  in do
    -- restart it
    -- change the state
    -- bump stats
    say $ "hmn, what to do with " ++ (show cSpec)
    continue $ state{ active = active' }

initKey :: ChildId -> ChildKey
initKey = (flip ChildKey) emptyChildPid

emptyChildPid :: Child
emptyChildPid = Child (undefined :: ProcessId)

tryStartChild :: State
              -> ChildSpec
              -> Process (Either TerminateReason ChildKey)
tryStartChild _ _ = undefined

store :: ChildKey -> ChildSpec -> State -> Process State
store key@(ChildKey chId _) spec state =
  let chType = childType spec
      specs' = Map.insert key spec (specs state)
      stats' = bumpStats chType $ stats state
  in return state{ specs = specs'
                 , maxId = chId
                 , stats = stats' }

bumpStats :: ChildType -> SupervisorStats -> SupervisorStats
bumpStats Worker s =
  let cs = childSpecCount s
      cw = childWorkerCount s
  in s{ childSpecCount = cs, childWorkerCount = cw }
bumpStats Supervisor s =
  let cs = childSpecCount s
      sw = childSupervisorCount s
  in s{ childSpecCount = cs, childSupervisorCount = sw }

nextId :: State -> Int
nextId = (+1) . maxId

-- GenProcess API

-- TODO: allow /init/ with existing spec list and start 'em up immediately

supInit :: InitHandler () State
supInit _ = return $ InitOk emptyState Infinity

emptyState :: State
emptyState = State {
    specs  = Map.empty
  , active = Map.empty
  , maxId  = 0
  , stats  = emptyStats
  }

emptyStats :: SupervisorStats
emptyStats = SupervisorStats {
    childSpecCount        = 0
  , childSupervisorCount  = 0
  , childWorkerCount      = 0
  , activeChildCount      = 0
  , activeSupervisorCount = 0
  , activeWorkerCount     = 0
  , totalRestarts         = 0
--  , avgRestartFrequency   = 0
  }
  -- TODO: usage/restart/freq stats

supServer :: ProcessDefinition State
supServer = ProcessDefinition {
     dispatchers = [
         handleCall handleLookupChild
       , handleCall handleAddChild
       , handleCall handleGetStats
       ]
   , infoHandlers = [handleInfo handleMonitorSignal]
   , timeoutHandler = undefined
   , terminateHandler = undefined
   , unhandledMessagePolicy = Drop
   }
