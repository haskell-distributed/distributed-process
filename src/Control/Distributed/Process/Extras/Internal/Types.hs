{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE DefaultSignatures      #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE UndecidableInstances   #-}

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
import Control.Distributed.Process hiding (send, catch)
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
import Control.Exception (SomeException)
import Control.Monad.Catch (catch)
import Data.Binary
import Data.Foldable (traverse_)
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

instance (NFSerializable a) => NFSerializable (SendPort a)

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

$(remotable ['whereis])

-- | A synchronous version of 'whereis', this monitors the remote node
-- and returns @Nothing@ if the node goes down (since a remote node failing
-- or being non-contactible has the same effect as a process not being
-- registered from the caller's point of view).
whereisRemote :: NodeId -> String -> Process (Maybe ProcessId)
whereisRemote node name = do
  mRef <- monitorNode node
  whereisRemoteAsync node name
  receiveWait [ matchIf (\(NodeMonitorNotification ref nid _) -> ref == mRef &&
                                                                 nid == node)
                        (\(NodeMonitorNotification _ _ _) -> return Nothing)
              , matchIf (\(WhereIsReply n _) -> n == name)
                        (\(WhereIsReply _ mPid) -> return mPid)
              ]

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

baseAddressableErrorMessage :: (Resolvable a) => a -> String
baseAddressableErrorMessage _ = "CannotResolveAddressable"

-- | Class of things to which a @Process@ can /link/ itself.
class Linkable a where
  -- | Create a /link/ with the supplied object.
  linkTo :: (Resolvable a) => a -> Process ()
  linkTo r = resolve r >>= traverse_ link

-- | Class of things that can be killed (or instructed to exit).
class Killable p where
  -- | Kill (instruct to exit) generic process, using 'kill' primitive.
  killProc :: Resolvable p => p -> String -> Process ()
  killProc r s = resolve r >>= traverse_ (flip kill $ s)

  -- | Kill (instruct to exit) generic process, using 'exit' primitive.
  exitProc :: (Resolvable p, Serializable m) => p -> m -> Process ()
  exitProc r m = resolve r >>= traverse_ (flip exit $ m)

instance Resolvable p => Killable p

-- | resolve the Resolvable or die with specified msg plus details of what didn't resolve
resolveOrDie  :: (Resolvable a) => a -> String -> Process ProcessId
resolveOrDie resolvable failureMsg = do
  result <- resolve resolvable
  case result of
    Nothing  -> die $ failureMsg ++ " " ++ unresolvableMessage resolvable
    Just pid -> return pid

-- | Class of things that can be resolved to a 'ProcessId'.
--
class Resolvable a where
  -- | Resolve the reference to a process id, or @Nothing@ if resolution fails
  resolve :: a -> Process (Maybe ProcessId)

  -- | Unresolvable @Addressable@ Message
  unresolvableMessage :: (Resolvable a) => a -> String
  unresolvableMessage = baseAddressableErrorMessage

instance Resolvable ProcessId where
  resolve p = return (Just p)
  unresolvableMessage p  = "CannotResolvePid[" ++ (show p) ++ "]"

instance Resolvable String where
  resolve = whereis
  unresolvableMessage s = "CannotResolveRegisteredName[" ++ s ++ "]"

instance Resolvable (NodeId, String) where
  resolve (nid, pname) =
    whereisRemote nid pname `catch` (\(_ :: SomeException) -> return Nothing)
  unresolvableMessage (n, s) =
    "CannotResolveRemoteRegisteredName[name: " ++ s ++ ", node: " ++ (show n) ++ "]"

-- Provide a unified API for addressing processes.

-- | Class of things that you can route/send serializable message to
class Routable a where

  -- | Send a message to the target asynchronously
  sendTo  :: (Serializable m, Resolvable a) => a -> m -> Process ()
  sendTo a m = do
    mPid <- resolve a
    maybe (die (unresolvableMessage a))
          (\p -> P.send p m)
          mPid

  -- | Send some @NFData@ message to the target asynchronously,
  -- forcing evaluation (i.e., @deepseq@) beforehand.
  unsafeSendTo :: (NFSerializable m, Resolvable a) => a -> m -> Process ()
  unsafeSendTo a m = do
    mPid <- resolve a
    maybe (die (unresolvableMessage a))
          (\p -> P.unsafeSend p $!! m)
          mPid

instance Routable ProcessId where
  sendTo                 = P.send
  unsafeSendTo pid msg   = P.unsafeSend pid $!! msg

instance Routable String where
  sendTo                = nsend
  unsafeSendTo name msg = P.unsafeNSend name $!! msg

instance Routable (NodeId, String) where
  sendTo  (nid, pname) = nsendRemote nid pname
  unsafeSendTo         = sendTo -- because serialisation *must* take place

instance Routable (Message -> Process ()) where
  sendTo f       = f . wrapMessage
  unsafeSendTo f = f . unsafeWrapMessage

class (Resolvable a, Routable a) => Addressable a
instance Addressable ProcessId

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

instance Resolvable Recipient where
  resolve (Pid                p) = return (Just p)
  resolve (Registered         n) = whereis n
  resolve (RemoteRegistered s n) = whereisRemote n s

  unresolvableMessage (Pid                p) = unresolvableMessage p
  unresolvableMessage (Registered         n) = unresolvableMessage n
  unresolvableMessage (RemoteRegistered s n) = unresolvableMessage (n, s)

-- although we have an instance of Routable for Resolvable, it really
-- makes no sense to do remote lookups on a pid, only to then send to it!
instance Routable Recipient where

  sendTo (Pid p)                m = P.send p m
  sendTo (Registered s)         m = nsend s m
  sendTo (RemoteRegistered s n) m = nsendRemote n s m

  unsafeSendTo (Pid p)                m = P.unsafeSend p $!! m
  unsafeSendTo (Registered s)         m = P.unsafeNSend s $!! m
  unsafeSendTo (RemoteRegistered s n) m = nsendRemote n s m

-- useful exit reasons

-- | Given when a server is unobtainable.
newtype ServerDisconnected = ServerDisconnected DiedReason
  deriving (Typeable, Generic)
instance Binary ServerDisconnected where
instance NFData ServerDisconnected where
