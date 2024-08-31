{-# LANGUAGE DeriveGeneric  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Supervisor.Types
-- Copyright   :  (c) Tim Watson 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-----------------------------------------------------------------------------
module Control.Distributed.Process.Supervisor.Types
  ( -- * Defining and Running a Supervisor
    ChildSpec(..)
  , ChildKey
  , ChildType(..)
  , ChildStopPolicy(..)
  , ChildStart(..)
  , RegisteredName(LocalName, CustomRegister)
  , RestartPolicy(..)
  , ChildRef(..)
  , isRunning
  , isRestarting
  , Child
  , StaticLabel
  , SupervisorPid
  , ChildPid
    -- * Limits and Defaults
  , MaxRestarts(..)
  , maxRestarts
  , RestartLimit(..)
  , limit
  , defaultLimits
  , RestartMode(..)
  , RestartOrder(..)
  , RestartStrategy(..)
  , ShutdownMode(..)
  , restartOne
  , restartAll
  , restartLeft
  , restartRight
    -- * Adding and Removing Children
  , AddChildResult(..)
  , StartChildResult(..)
  , StopChildResult(..)
  , DeleteChildResult(..)
  , RestartChildResult(..)
    -- * Additional (Misc) Types
  , SupervisorStats(..)
  , StartFailure(..)
  , ChildInitFailure(..)
  , MxSupervisor(..)
  ) where

import GHC.Generics
import Data.Typeable (Typeable)
import Data.Binary

import Control.DeepSeq (NFData)
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Extras.Internal.Types
  ( ExitReason(..)
  )
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Internal.Primitives hiding (monitor)
import Control.Exception (Exception)
import Data.Hashable (Hashable)

-- aliases for api documentation purposes

-- | The "ProcessId" of a supervisor.
type SupervisorPid = ProcessId

-- | The "ProcessId" of a supervised /child/.
type ChildPid = ProcessId

-- | The maximum number of restarts a supervisor will tollerate, created by
-- evaluating "maxRestarts".
newtype MaxRestarts = MaxR { maxNumberOfRestarts :: Int }
  deriving (Typeable, Generic, Show)
instance Binary MaxRestarts where
instance Hashable MaxRestarts where
instance NFData MaxRestarts where

-- | Smart constructor for @MaxRestarts@. The maximum restart count must be a
-- positive integer, otherwise you will see @error "MaxR must be >= 0"@.
maxRestarts :: Int -> MaxRestarts
maxRestarts r | r >= 0    = MaxR r
              | otherwise = error "MaxR must be >= 0"

-- | A compulsary limit on the number of restarts that a supervisor will
-- tolerate before it stops all child processes and then itself.
-- If > @MaxRestarts@ occur within the specified @TimeInterval@, the child
-- will be stopped. This prevents the supervisor from entering an infinite loop
-- of child process stops and restarts.
--
data RestartLimit =
  RestartLimit
  { maxR :: !MaxRestarts
  , maxT :: !TimeInterval
  }
  deriving (Typeable, Generic, Show)
instance Binary RestartLimit where
instance NFData RestartLimit where

-- | Smart constructor for "RestartLimit".
limit :: MaxRestarts -> TimeInterval -> RestartLimit
limit mr = RestartLimit mr

-- | Default "RestartLimit" of @MaxR 1@ within @Seconds 1@.
defaultLimits :: RestartLimit
defaultLimits = limit (MaxR 1) (seconds 1)

-- | Specifies the order in which a supervisor should apply restarts.
data RestartOrder = LeftToRight | RightToLeft
  deriving (Typeable, Generic, Eq, Show)
instance Binary RestartOrder where
instance Hashable RestartOrder where
instance NFData RestartOrder where

-- | Instructs a supervisor on how to restart its children.
data RestartMode =
    RestartEach     { order :: !RestartOrder }
    {- ^ stop then start each child sequentially, i.e., @foldlM stopThenStart children@ -}
  | RestartInOrder  { order :: !RestartOrder }
    {- ^ stop all children first, then restart them sequentially -}
  | RestartRevOrder { order :: !RestartOrder }
    {- ^ stop all children in the given order, but start them in reverse -}
  deriving (Typeable, Generic, Show, Eq)
instance Binary RestartMode where
instance Hashable RestartMode where
instance NFData RestartMode where

-- | Instructs a supervisor on how to instruct its children to stop running
-- when the supervisor itself is shutting down.
data ShutdownMode = SequentialShutdown !RestartOrder
                      | ParallelShutdown
  deriving (Typeable, Generic, Show, Eq)
instance Binary ShutdownMode where
instance Hashable ShutdownMode where
instance NFData ShutdownMode where

-- | Strategy used by a supervisor to handle child restarts, whether due to
-- unexpected child failure or explicit restart requests from a client.
--
-- Some terminology: We refer to child processes managed by the same supervisor
-- as /siblings/. When restarting a child process, the 'RestartNone' policy
-- indicates that sibling processes should be left alone, whilst the 'RestartAll'
-- policy will cause /all/ children to be restarted (in the same order they were
-- started).
--
-- The other two restart strategies refer to /prior/ and /subsequent/
-- siblings, which describe's those children's configured position in insertion
-- order in the child specs. These latter modes allow one to control the order
-- in which siblings are restarted, and to exclude some siblings from restarting,
-- without having to resort to grouping them using a child supervisor.
--
data RestartStrategy =
    RestartOne
    { intensity        :: !RestartLimit
    } -- ^ restart only the failed child process
  | RestartAll
    { intensity        :: !RestartLimit
    , mode             :: !RestartMode
    } -- ^ also restart all siblings
  | RestartLeft
    { intensity        :: !RestartLimit
    , mode             :: !RestartMode
    } -- ^ restart prior siblings (i.e., prior /start order/)
  | RestartRight
    { intensity        :: !RestartLimit
    , mode             :: !RestartMode
    } -- ^ restart subsequent siblings (i.e., subsequent /start order/)
  deriving (Typeable, Generic, Show)
instance Binary RestartStrategy where
instance NFData RestartStrategy where

-- | Provides a default 'RestartStrategy' for @RestartOne@.
-- > restartOne = RestartOne defaultLimits
--
restartOne :: RestartStrategy
restartOne = RestartOne defaultLimits

-- | Provides a default 'RestartStrategy' for @RestartAll@.
-- > restartOne = RestartAll defaultLimits (RestartEach LeftToRight)
--
restartAll :: RestartStrategy
restartAll = RestartAll defaultLimits (RestartEach LeftToRight)

-- | Provides a default 'RestartStrategy' for @RestartLeft@.
-- > restartOne = RestartLeft defaultLimits (RestartEach LeftToRight)
--
restartLeft :: RestartStrategy
restartLeft = RestartLeft defaultLimits (RestartEach LeftToRight)

-- | Provides a default 'RestartStrategy' for @RestartRight@.
-- > restartOne = RestartRight defaultLimits (RestartEach LeftToRight)
--
restartRight :: RestartStrategy
restartRight = RestartRight defaultLimits (RestartEach LeftToRight)

-- | Identifies a child process by name.
type ChildKey = String

-- | A reference to a (possibly running) child.
data ChildRef =
    ChildRunning !ChildPid     -- ^ a reference to the (currently running) child
  | ChildRunningExtra !ChildPid !Message -- ^ also a currently running child, with /extra/ child info
  | ChildRestarting !ChildPid  -- ^ a reference to the /old/ (previous) child (now restarting)
  | ChildStopped               -- ^ indicates the child is not currently running
  | ChildStartIgnored          -- ^ a non-temporary child exited with 'ChildInitIgnore'
  deriving (Typeable, Generic, Show)
instance Binary ChildRef where
instance NFData ChildRef where

instance Eq ChildRef where
  ChildRunning      p1   == ChildRunning      p2   = p1 == p2
  ChildRunningExtra p1 _ == ChildRunningExtra p2 _ = p1 == p2
  ChildRestarting   p1   == ChildRestarting   p2   = p1 == p2
  ChildStopped           == ChildStopped           = True
  ChildStartIgnored      == ChildStartIgnored      = True
  _                      == _                      = False

-- | @True@ if "ChildRef" is running.
isRunning :: ChildRef -> Bool
isRunning (ChildRunning _)        = True
isRunning (ChildRunningExtra _ _) = True
isRunning _                       = False

-- | @True@ if "ChildRef" is restarting
isRestarting :: ChildRef -> Bool
isRestarting (ChildRestarting _) = True
isRestarting _                   = False

instance Resolvable ChildRef where
  resolve (ChildRunning pid)        = return $ Just pid
  resolve (ChildRunningExtra pid _) = return $ Just pid
  resolve _                         = return Nothing

-- these look a bit odd, but we basically want to avoid resolving
-- or sending to (ChildRestarting oldPid)
instance Routable ChildRef where
  sendTo (ChildRunning addr) = sendTo addr
  sendTo _                   = error "invalid address for child process"

  unsafeSendTo (ChildRunning ch) = unsafeSendTo ch
  unsafeSendTo _                 = error "invalid address for child process"

-- | Specifies whether the child is another supervisor, or a worker.
data ChildType = Worker | Supervisor
  deriving (Typeable, Generic, Show, Eq)
instance Binary ChildType where
instance NFData ChildType where

-- | Describes when a stopped child process should be restarted.
data RestartPolicy =
    Permanent  -- ^ a permanent child will always be restarted
  | Temporary  -- ^ a temporary child will /never/ be restarted
  | Transient  -- ^ A transient child will be restarted only if it stops abnormally
  | Intrinsic  -- ^ as 'Transient', but if the child exits normally, the supervisor also exits normally
  deriving (Typeable, Generic, Eq, Show)
instance Binary RestartPolicy where
instance NFData RestartPolicy where

-- | Governs how the supervisor will instruct child processes to stop.
data ChildStopPolicy =
    StopTimeout !Delay
  | StopImmediately
  deriving (Typeable, Generic, Eq, Show)
instance Binary ChildStopPolicy where
instance NFData ChildStopPolicy where

-- | Represents a registered name, for registration /locally/ using the
-- @register@ primitive, or via a @Closure (ChildPid -> Process ())@ such that
-- registration can be performed using alternative process registries.
data RegisteredName =
    LocalName          !String
  | CustomRegister     !(Closure (ChildPid -> Process ()))
  deriving (Typeable, Generic)
instance Binary RegisteredName where
instance NFData RegisteredName where

instance Show RegisteredName where
  show (CustomRegister _) = "Custom Register"
  show (LocalName      n) = n

-- | Defines the way in which a child process is to be started.
data ChildStart =
    RunClosure !(Closure (Process ()))
  | CreateHandle !(Closure (SupervisorPid -> Process (ChildPid, Message)))
  deriving (Typeable, Generic, Show)
instance Binary ChildStart where
instance NFData ChildStart  where

-- | Specification for a child process. The child must be uniquely identified
-- by it's @childKey@ within the supervisor. The supervisor will start the child
-- itself, therefore @childRun@ should contain the child process' implementation
-- e.g., if the child is a long running server, this would be the server /loop/,
-- as with e.g., @ManagedProces.start@.
data ChildSpec = ChildSpec {
    childKey          :: !ChildKey
  , childType         :: !ChildType
  , childRestart      :: !RestartPolicy
  , childRestartDelay :: !(Maybe TimeInterval)
  , childStop         :: !ChildStopPolicy
  , childStart        :: !ChildStart
  , childRegName      :: !(Maybe RegisteredName)
  } deriving (Typeable, Generic, Show)
instance Binary ChildSpec where
instance NFData ChildSpec where

-- | A child process failure during init will be reported using this datum
data ChildInitFailure =
    ChildInitFailure !String -- ^ The init failed with the corresponding message
  | ChildInitIgnore -- ^ The child told the supervisor to ignore its startup procedure
  deriving (Typeable, Generic, Show)
instance Binary ChildInitFailure where
instance NFData ChildInitFailure where
instance Exception ChildInitFailure where

-- | Statistics about a running supervisor
data SupervisorStats = SupervisorStats {
    _children          :: Int
  , _supervisors       :: Int
  , _workers           :: Int
  , _running           :: Int
  , _activeSupervisors :: Int
  , _activeWorkers     :: Int
  -- TODO: usage/restart/freq stats
  , totalRestarts      :: Int
  } deriving (Typeable, Generic, Show)
instance Binary SupervisorStats where
instance NFData SupervisorStats where

-- | Supervisor event data published to the management API
data MxSupervisor =
    SupervisorBranchRestarted
    {
      supervisorPid  :: SupervisorPid
    , childSpecKey   :: ChildKey
    , diedReason     :: DiedReason
    , branchStrategy :: RestartStrategy
    } -- ^ A branch restart took place
  | SupervisedChildRestarting
    { supervisorPid :: SupervisorPid
    , childInScope  :: Maybe ChildPid
    , childSpecKey  :: ChildKey
    , exitReason    :: ExitReason
    } -- ^ A child is being restarted
  | SupervisedChildStarted
    { supervisorPid :: SupervisorPid
    , childRef      :: ChildRef
    , childSpecKey  :: ChildKey
    } -- ^ A child has been started
  | SupervisedChildStartFailure
    { supervisorPid :: SupervisorPid
    , startFailure  :: StartFailure
    , childSpecKey  :: ChildKey
    } -- ^ A child failed to start
  | SupervisedChildDied
    { supervisorPid :: SupervisorPid
    , childPid      :: ChildPid
    , exitReason    :: ExitReason
    } -- ^ A child process death was detected
  | SupervisedChildInitFailed
    { supervisorPid :: SupervisorPid
    , childPid      :: ChildPid
    , initFailure   :: ChildInitFailure
    } -- ^ A child failed during init
  | SupervisedChildStopped
    { supervisorPid :: SupervisorPid
    , childRef      :: ChildRef
    , diedReason    :: DiedReason
    } -- ^ A child has been stopped
  | SupervisorShutdown
    { supervisorPid :: SupervisorPid
    , shutdownMode  :: ShutdownMode
    , exitRason     :: ExitReason
    } -- ^ A supervisor is shutting down
    deriving (Typeable, Generic, Show)
instance Binary MxSupervisor where
instance NFData MxSupervisor where

-- | Static labels (in the remote table) are strings.
type StaticLabel = String

-- | Provides failure information when (re-)start failure is indicated.
data StartFailure =
    StartFailureDuplicateChild !ChildRef -- ^ a child with this 'ChildKey' already exists
  | StartFailureAlreadyRunning !ChildRef -- ^ the child is already up and running
  | StartFailureBadClosure !StaticLabel  -- ^ a closure cannot be resolved
  | StartFailureDied !DiedReason         -- ^ a child died (almost) immediately on starting
  deriving (Typeable, Generic, Show, Eq)
instance Binary StartFailure where
instance NFData StartFailure where

-- | The result of a call to 'removeChild'.
data DeleteChildResult =
    ChildDeleted              -- ^ the child specification was successfully removed
  | ChildNotFound             -- ^ the child specification was not found
  | ChildNotStopped !ChildRef -- ^ the child was not removed, as it was not stopped.
  deriving (Typeable, Generic, Show, Eq)
instance Binary DeleteChildResult where
instance NFData DeleteChildResult where

-- | A child represented as a @(ChildRef, ChildSpec)@ pair.
type Child = (ChildRef, ChildSpec)

-- exported result types of internal APIs

-- | The result of an @addChild@ request.
data AddChildResult =
    ChildAdded         !ChildRef  -- ^ The child was added correctly
  | ChildFailedToStart !StartFailure -- ^ The child failed to start
  deriving (Typeable, Generic, Show, Eq)
instance Binary AddChildResult where
instance NFData AddChildResult where

-- | The result of a @startChild@ request.
data StartChildResult =
    ChildStartOk        !ChildRef     -- ^ The child started successfully
  | ChildStartFailed    !StartFailure -- ^ The child failed to start
  | ChildStartUnknownId               -- ^ The child key was not recognised by the supervisor
  deriving (Typeable, Generic, Show, Eq)
instance Binary StartChildResult where
instance NFData StartChildResult where

-- | The result of a @restartChild@ request.
data RestartChildResult =
    ChildRestartOk     !ChildRef     -- ^ The child restarted successfully
  | ChildRestartFailed !StartFailure -- ^ The child failed to restart
  | ChildRestartUnknownId            -- ^ The child key was not recognised by the supervisor
  deriving (Typeable, Generic, Show, Eq)

instance Binary RestartChildResult where
instance NFData RestartChildResult where

-- | The result of a @stopChild@ request.
data StopChildResult =
    StopChildOk -- ^ The child was stopped successfully
  | StopChildUnknownId -- ^ The child key was not recognised by the supervisor
  deriving (Typeable, Generic, Show, Eq)
instance Binary StopChildResult where
instance NFData StopChildResult where
