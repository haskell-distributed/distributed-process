{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE PatternGuards              #-}
module Control.Distributed.Process.Management.Internal.Types
  ( MxAgentId(..)
  , MxAgentState(..)
  , MxAgent(..)
  , MxAction(..)
  , ChannelSelector(..)
  , Fork
  , MxSink
  , MxEvent(..)
  , Destination(..)
  , Addressable(..)
  ) where

import Control.Applicative (Applicative)
import Control.Concurrent.STM
  ( TChan
  )
import Control.DeepSeq (NFData(..))
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , Message
  , SendPort
  , DiedReason
  , NodeId
  )
import Control.Monad.IO.Class (MonadIO)
import qualified Control.Monad.State as ST
  ( MonadState
  , StateT
  )
import Data.Binary
import Data.Typeable (Typeable)
import GHC.Generics
import Network.Transport
  ( ConnectionId
  , EndPointAddress
  )

-- | A simple means of mapping send events to their destinations
data Destination = 
    ProcId             { procId   :: !ProcessId }
  | ProcName           { procName :: !String    }
  | RemoteProcName     { procName :: !String
                       , procNode :: !NodeId    }
  | UserDefined        { userData :: !Message   }
  deriving (Typeable, Generic, Show)
instance Binary Destination where
instance NFData Destination where
  rnf (ProcId p)           = rnf p `seq` ()
  rnf (ProcName s)         = rnf s `seq` ()
  rnf (RemoteProcName s n) = rnf s `seq` rnf n `seq` ()
  rnf (UserDefined m)      = rnf m `seq` ()

-- | This is the /default/ management event, fired for various internal
-- events around the NT connection and Process lifecycle. All published
-- events that conform to this type, are eligible for tracing - i.e.,
-- they will be delivered to the trace controller.
--
data MxEvent =
    MxSpawned          { whichProcess :: ProcessId }
    -- ^ fired whenever a local process is spawned
  | MxRegistered       { whichProcess :: ProcessId
                       , whichName    :: String
                       }
    -- ^ fired whenever a process/name is registered (locally)
  | MxUnRegistered     { whichProcess :: ProcessId
                       , whichName    :: String
                       }
    -- ^ fired whenever a process/name is unregistered (locally)
  | MxProcessDied      { whichProcess :: ProcessId
                       , why          :: DiedReason
                       }
    -- ^ fired whenever a process dies
  | MxNodeDied         { whichNode    :: NodeId
                       , why          :: DiedReason
                       }
    -- ^ fired whenever a node /dies/ (i.e., the connection is broken/disconnected)
  | MxSent             { whichProcess :: ProcessId
                       , whereTo      :: Destination
                       , message      :: Message
                       }
    -- ^ fired whenever a message is sent from a local process
  | MxReceived         { whichProcess  :: ProcessId
                       , message       :: Message
                       }
    -- ^ fired whenever a message is received by a local process
  | MxConnected        { whichConnection :: ConnectionId
                       , whichEndoint    :: EndPointAddress
                       }
    -- ^ fired when a network-transport connection is first established
  | MxDisconnected     { whichConnection :: ConnectionId
                       , whichEndpoint   :: EndPointAddress
                       }
    -- ^ fired when a network-transport connection is broken/disconnected
  | MxUser             { message :: Message }
    -- ^ a user defined trace event
  | MxLog              { test :: String }
    -- ^ a /logging/ event - used for debugging purposes only
  | MxTraceTakeover    { whichProcess :: ProcessId }
    -- ^ notifies a trace listener that all subsequent traces will be sent to /pid/
  | MxTraceDisable
    -- ^ notifies a trace listener that it has been disabled/removed
    deriving (Typeable, Generic, Show)

instance Binary MxEvent where

-- | The class of things that we might be able to resolve to
-- a @ProcessId@ (or not).
class Addressable a where
  resolveToPid :: a -> Maybe ProcessId

instance Addressable Destination where
  resolveToPid dest
    | (ProcId pid) <- dest = Just pid
    | otherwise            = Nothing

instance Addressable MxEvent where
  resolveToPid (MxSpawned     p)     = Just p
  resolveToPid (MxProcessDied p _)   = Just p
  resolveToPid (MxSent        _ p _) = resolveToPid p
  resolveToPid (MxReceived    p _)   = Just p
  resolveToPid _                     = Nothing

-- | Gross though it is, this synonym represents a function
-- used to forking new processes, which has to be passed as a HOF
-- when calling mxAgentController, since there's no other way to
-- avoid a circular dependency with Node.hs
type Fork = (Process () -> IO ProcessId)

-- | A newtype wrapper for an agent id (which is a string).
newtype MxAgentId = MxAgentId { agentId :: String }
  deriving (Typeable, Binary, Eq, Ord)

data MxAgentState s = MxAgentState
                      {
                        mxAgentId     :: !MxAgentId
                      , mxBus         :: !(TChan Message)
                      , mxLocalState  :: !s
                      }

-- | Monad for management agents.
--
newtype MxAgent s a =
  MxAgent
  {
    unAgent :: ST.StateT (MxAgentState s) Process a
  } deriving ( Functor
             , Monad
             , MonadIO
             , ST.MonadState (MxAgentState s)
             , Typeable
             , Applicative
             )

data ChannelSelector = InputChan | Mailbox

-- | Represents the actions a management agent can take
-- when evaluating an /event sink/.
--
data MxAction =
    MxAgentDeactivate !String
  | MxAgentPrioritise !ChannelSelector
  | MxAgentReady
  | MxAgentSkip

-- | Type of a management agent's event sink.
type MxSink s = Message -> MxAgent s (Maybe MxAction)
