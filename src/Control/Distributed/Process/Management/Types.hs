{-# LANGUAGE DeriveGeneric   #-}
module Control.Distributed.Process.Management.Types
  ( MxAgentId(..)
  , MxTableId(..)
  , MxAgentState(..)
  , MxAgent(..)
  , MxAgentStart(..)
  , Fork
  ) where

import Control.Applicative (Applicative)
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , Message
  , SendPort
  )
import Control.Monad.IO.Class (MonadIO)
import qualified Control.Monad.State as ST
  ( MonadState
  , StateT
  , get
  , lift
  , runStateT
  )
import Data.Binary (Binary)
import Data.Map.Strict (Map)
import Data.Typeable (Typeable)
import GHC.Generics

-- | Gross though it is, this synonym represents a function
-- used to forking new processes, which has to be passed as a HOF
-- when calling mxAgentController, since there's no other way to
-- avoid a circular dependency with Node.hs
type Fork = (Process () -> IO ProcessId)

-- | A newtype wrapper for an agent id (which is a string).
newtype MxAgentId = MxAgentId { agentId :: String }
  deriving (Typeable, Binary, Eq, Ord)

data MxTableId =
    MxForAgent !MxAgentId
  | MxForPid   !ProcessId

data MxAgentState s = MxAgentState
                      {
                        mxAgentId     :: !MxAgentId
                    -- , mxBus       :: !(TChan Message)
                      , mxSharedTable :: !ProcessId
                      , mxLocalState  :: !s
                      }

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

data MxAgentStart = MxAgentStart
                    {
                      mxAgentTableChan :: SendPort ProcessId
                    , mxAgentIdStart   :: MxAgentId
                    }
  deriving (Typeable, Generic)
instance Binary MxAgentStart where

