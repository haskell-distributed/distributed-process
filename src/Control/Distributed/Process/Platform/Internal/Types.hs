{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE TemplateHaskell           #-}

-- | Types used throughout the Cloud Haskell framework
--
module Control.Distributed.Process.Platform.Internal.Types
  ( -- * Tagging
    Tag
  , TagPool
  , newTagPool
  , getTag
    -- * Addressing
  , sendToRecipient
  , Recipient(..)
  , RegisterSelf(..)
    -- * Interactions
  , whereisRemote
  , CancelWait(..)
  , Channel
  , Shutdown(..)
  , ExitReason(..)
    -- remote table
  , __remoteTable
  ) where

import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , modifyMVar
  )
import Control.Distributed.Process hiding (send)
import qualified Control.Distributed.Process as P (send)
import Control.Distributed.Process.Closure
  ( remotable
  , mkClosure
  , functionTDict
  )
import Control.Distributed.Process.Serializable

import Data.Binary
import Data.Typeable (Typeable)

import GHC.Generics

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Tags provide uniqueness for messages, so that they can be
-- matched with their response.
type Tag = Int

-- | Generates unique 'Tag' for messages and response pairs.
-- Each process that depends, directly or indirectly, on
-- the call mechanisms in "Control.Distributed.Process.Global.Call"
-- should have at most one TagPool on which to draw unique message
-- tags.
type TagPool = MVar Tag

-- | Create a new per-process source of unique
-- message identifiers.
newTagPool :: Process TagPool
newTagPool = liftIO $ newMVar 0

-- | Extract a new identifier from a 'TagPool'.
getTag :: TagPool -> Process Tag
getTag tp = liftIO $ modifyMVar tp (\tag -> return (tag+1,tag))

-- | Wait cancellation message.
data CancelWait = CancelWait
    deriving (Eq, Show, Typeable, Generic)
instance Binary CancelWait where

-- | Simple representation of a channel.
type Channel a = (SendPort a, ReceivePort a)

-- | Used internally in whereisOrStart. Send as (RegisterSelf,ProcessId).
data RegisterSelf = RegisterSelf
  deriving (Typeable, Generic)
instance Binary RegisterSelf where

data Recipient =
    Pid ProcessId
  | Registered String
  | RemoteRegistered String NodeId
  deriving (Typeable, Generic, Show, Eq)
instance Binary Recipient where

sendToRecipient :: (Serializable m) => Recipient -> m -> Process ()
sendToRecipient (Pid p) m                = P.send p m
sendToRecipient (Registered s) m         = nsend s m
sendToRecipient (RemoteRegistered s n) m = nsendRemote n s m

$(remotable ['whereis])

-- | A synchronous version of 'whereis', this relies on 'call'
-- to perform the relevant monitoring of the remote node.
whereisRemote :: NodeId -> String -> Process (Maybe ProcessId)
whereisRemote node name =
  call $(functionTDict 'whereis) node ($(mkClosure 'whereis) name)

-- | A ubiquitous /shutdown signal/ that can be used
-- to maintain a consistent shutdown/stop protocol for
-- any process that wishes to handle it.
data Shutdown = Shutdown
  deriving (Typeable, Generic, Show, Eq)
instance Binary Shutdown where

-- | Provides a /reason/ for process termination.
data ExitReason =
    ExitNormal        -- ^ indicates normal exit
  | ExitShutdown      -- ^ normal response to a 'Shutdown'
  | ExitOther !String -- ^ abnormal (error) shutdown
  deriving (Typeable, Generic, Eq, Show)
instance Binary ExitReason where

