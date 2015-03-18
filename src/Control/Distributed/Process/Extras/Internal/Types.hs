{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE OverlappingInstances   #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}

-- | Types used throughout the Extras package
--
module Control.Distributed.Process.Extras.Internal.Types
  ( -- * Tagging
    Tag
  , TagPool
  , newTagPool
  , getTag
    -- * Addressing
  , Linkable(..)
  , Killable(..)
  , Resolvable(..)
  , Routable(..)
  , Addressable
  , sendToRecipient
  , Recipient(..)
  , RegisterSelf(..)
    -- * Interactions
  , whereisRemote
  , resolveOrDie
  , CancelWait(..)
  , Channel
  , Shutdown(..)
  , ExitReason(..)
  , ServerDisconnected(..)
  , NFSerializable
    -- remote table
  , __remoteTable
  ) where

import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , modifyMVar
  )
import Control.DeepSeq (NFData(..), ($!!))
import Control.Distributed.Process hiding (send)
import qualified Control.Distributed.Process as P
  ( send
  , unsafeSend
  , unsafeNSend
  )
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

-- | Introduces a class that brings NFData into scope along with Serializable,
-- such that we can force evaluation. Intended for use with the UnsafePrimitives
-- module (which wraps "Control.Distributed.Process.UnsafePrimitives"), and
-- guarantees evaluatedness in terms of @NFData@. Please note that we /cannot/
-- guarantee that an @NFData@ instance will behave the same way as a @Binary@
-- one with regards evaluation, so it is still possible to introduce unexpected
-- behaviour by using /unsafe/ primitives in this way.
--
class (NFData a, Serializable a) => NFSerializable a
instance (NFData a, Serializable a) => NFSerializable a

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
instance NFData CancelWait where

-- | Simple representation of a channel.
type Channel a = (SendPort a, ReceivePort a)

-- | Used internally in whereisOrStart. Sent as (RegisterSelf,ProcessId).
data RegisterSelf = RegisterSelf
  deriving (Typeable, Generic)
instance Binary RegisterSelf where
instance NFData RegisterSelf where

-- | A ubiquitous /shutdown signal/ that can be used
-- to maintain a consistent shutdown/stop protocol for
-- any process that wishes to handle it.
data Shutdown = Shutdown
  deriving (Typeable, Generic, Show, Eq)
instance Binary Shutdown where
instance NFData Shutdown where

-- | Provides a /reason/ for process termination.
data ExitReason =
    ExitNormal        -- ^ indicates normal exit
  | ExitShutdown      -- ^ normal response to a 'Shutdown'
  | ExitOther !String -- ^ abnormal (error) shutdown
  deriving (Typeable, Generic, Eq, Show)
instance Binary ExitReason where
instance NFData ExitReason where

-- | A simple means of mapping to a receiver.
data Recipient =
    Pid !ProcessId
  | Registered !String
  | RemoteRegistered !String !NodeId
--  | ProcReg !ProcessId !String
--  | RemoteProcReg NodeId String
--  | GlobalReg String
  deriving (Typeable, Generic, Show, Eq)
instance Binary Recipient where
instance NFData Recipient where
  rnf (Pid p) = rnf p `seq` ()
  rnf (Registered s) = rnf s `seq` ()
  rnf (RemoteRegistered s n) = rnf s `seq` rnf n `seq` ()

-- useful exit reasons

-- | Given when a server is unobtainable.
data ServerDisconnected = ServerDisconnected !DiedReason
  deriving (Typeable, Generic)
instance Binary ServerDisconnected where
instance NFData ServerDisconnected where

$(remotable ['whereis])

-- | A synchronous version of 'whereis', this relies on 'call'
-- to perform the relevant monitoring of the remote node.
whereisRemote :: NodeId -> String -> Process (Maybe ProcessId)
whereisRemote node name =
  call $(functionTDict 'whereis) node ($(mkClosure 'whereis) name)

sendToRecipient :: (Serializable m) => Recipient -> m -> Process ()
sendToRecipient (Pid p) m                = P.send p m
sendToRecipient (Registered s) m         = nsend s m
sendToRecipient (RemoteRegistered s n) m = nsendRemote n s m

unsafeSendToRecipient :: (NFSerializable m) => Recipient -> m -> Process ()
unsafeSendToRecipient (Pid p) m                = P.unsafeSend p $!! m
unsafeSendToRecipient (Registered s) m         = P.unsafeNSend s $!! m
unsafeSendToRecipient (RemoteRegistered s n) m = nsendRemote n s m

baseAddressableErrorMessage :: (Routable a) => a -> String
baseAddressableErrorMessage _ = "CannotResolveAddressable"

-- | Class of things to which a @Process@ can /link/ itself.
class Linkable a where
  -- | Create a /link/ with the supplied object.
  linkTo :: a -> Process ()

-- | Class of things that can be resolved to a 'ProcessId'.
--
class Resolvable a where
  -- | Resolve the reference to a process id, or @Nothing@ if resolution fails
  resolve :: a -> Process (Maybe ProcessId)

-- | Class of things that can be killed (or instructed to exit).
class Killable a where
  killProc :: a -> String -> Process ()
  exitProc :: (Serializable m) => a -> m -> Process ()

instance Killable ProcessId where
  killProc = kill
  exitProc = exit

instance Resolvable r => Killable r where
  killProc r s = resolve r >>= maybe (return ()) (flip kill $ s)
  exitProc r m = resolve r >>= maybe (return ()) (flip exit $ m)

-- | Provides a unified API for addressing processes.
--
class Routable a where
  -- | Send a message to the target asynchronously
  sendTo  :: (Serializable m) => a -> m -> Process ()

  -- | Send some @NFData@ message to the target asynchronously,
  -- forcing evaluation (i.e., @deepseq@) beforehand.
  unsafeSendTo :: (NFSerializable m) => a -> m -> Process ()

  -- | Unresolvable @Addressable@ Message
  unresolvableMessage :: a -> String
  unresolvableMessage = baseAddressableErrorMessage

instance (Resolvable a) => Routable a where
  sendTo a m = do
    mPid <- resolve a
    maybe (die (unresolvableMessage a))
          (\p -> P.send p m)
          mPid

  unsafeSendTo a m = do
    mPid <- resolve a
    maybe (die (unresolvableMessage a))
          (\p -> P.unsafeSend p $!! m)
          mPid

  -- | Unresolvable Addressable Message
  unresolvableMessage = baseAddressableErrorMessage

instance Resolvable Recipient where
  resolve (Pid                p) = return (Just p)
  resolve (Registered         n) = whereis n
  resolve (RemoteRegistered s n) = whereisRemote n s

instance Routable Recipient where
  sendTo = sendToRecipient
  unsafeSendTo = unsafeSendToRecipient

  unresolvableMessage (Pid                p) = unresolvableMessage p
  unresolvableMessage (Registered         n) = unresolvableMessage n
  unresolvableMessage (RemoteRegistered s n) = unresolvableMessage (n, s)

instance Resolvable ProcessId where
  resolve p = return (Just p)

instance Routable ProcessId where
  sendTo                 = P.send
  unsafeSendTo pid msg   = P.unsafeSend pid $!! msg
  unresolvableMessage p  = "CannotResolvePid[" ++ (show p) ++ "]"

instance Resolvable String where
  resolve = whereis

instance Routable String where
  sendTo                = nsend
  unsafeSendTo name msg = P.unsafeNSend name $!! msg
  unresolvableMessage s = "CannotResolveRegisteredName[" ++ s ++ "]"

instance Resolvable (NodeId, String) where
  resolve (nid, pname) = whereisRemote nid pname

instance Routable (NodeId, String) where
  sendTo  (nid, pname) msg   = nsendRemote nid pname msg
  unsafeSendTo               = sendTo -- because serialisation *must* take place
  unresolvableMessage (n, s) =
    "CannotResolveRemoteRegisteredName[name: " ++ s ++ ", node: " ++ (show n) ++ "]"

instance Routable (Message -> Process ()) where
  sendTo f       = f . wrapMessage
  unsafeSendTo f = f . unsafeWrapMessage

class (Resolvable a, Routable a) => Addressable a
instance (Resolvable a, Routable a) => Addressable a

-- TODO: this probably belongs somewhere other than in ..Types.
-- | resolve the Resolvable or die with specified msg plus details of what didn't resolve
resolveOrDie  :: (Routable a, Resolvable a) => a -> String -> Process ProcessId
resolveOrDie resolvable failureMsg = do
  result <- resolve resolvable
  case result of
    Nothing -> die $ failureMsg ++ " " ++ unresolvableMessage resolvable
    Just pid -> return pid
