{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE PatternGuards             #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE OverlappingInstances      #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Supervisor
-- Copyright   :  (c) Tim Watson 2012 - 2013
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module implements a process which supervises a set of other
-- processes, referred to as its children. These /child processes/ can be
-- either workers (i.e., processes that do something useful in your application)
-- or other supervisors. In this way, supervisors may be used to build a
-- hierarchical process structure called a supervision tree, which provides
-- a convenient structure for building fault tolerant software.
--
-- Unless otherwise stated, all functions in this module will cause the calling
-- process to exit unless the specified supervisor process exists.
--
-- [Supervision Principles]
--
-- A supervisor is responsible for starting, stopping and monitoring its child
-- processes so as to keep them alive by restarting them when necessary.
--
-- The supervisors children are defined as a list of child specifications
-- (see 'ChildSpec'). When a supervisor is started, its children are started
-- in left-to-right (insertion order) according to this list. When a supervisor
-- stops (or exits for any reason), it will terminate its children in reverse
-- (i.e., from right-to-left of insertion) order. Child specs can be added to
-- the supervisor after it has started, either on the left or right of the
-- existing list of children.
--
-- When the supervisor spawns its child processes, they are always linked to
-- their parent (i.e., the supervisor), therefore even if the supervisor is
-- terminated abruptly by an asynchronous exception, the children will still be
-- taken down with it, though somewhat less ceremoniously in that case.
--
-- [Restart Strategies]
--
-- Supervisors are initialised with a 'RestartStrategy', which describes how
-- the supervisor should respond to a child that exits and should be restarted
-- (see below for the rules governing child restart eligibility). Each restart
-- strategy comprises a 'RestartMode' and 'RestartLimit', which govern how
-- the restart should be handled, and the point at which the supervisor
-- should give up and terminate itself respectively.
--
-- With the exception of the @RestartOne@ strategy, which indicates that the
-- supervisor will restart /only/ the one individual failing child, each
-- strategy describes a way to select the set of children that should be
-- restarted if /any/ child fails. The @RestartAll@ strategy, as its name
-- suggests, selects /all/ children, whilst the @RestartLeft@ and @RestartRight@
-- strategies select /all/ children to the left or right of the failed child,
-- in insertion (i.e., startup) order.
--
-- Note that a /branch/ restart will only occur if the child that exited is
-- meant to be restarted. Since @Temporary@ children are never restarted and
-- @Transient@ children are /not/ restarted if they exit normally, in both these
-- circumstances we leave the remaining supervised children alone. Otherwise,
-- the failing child is /always/ included in the /branch/ to be restarted.
--
-- For a hypothetical set of children @a@ through @d@, the following pseudocode
-- demonstrates how the restart strategies work.
--
-- > let children = [a..d]
-- > let failure = c
-- > restartsFor RestartOne   children failure = [c]
-- > restartsFor RestartAll   children failure = [a,b,c,d]
-- > restartsFor RestartLeft  children failure = [a,b,c]
-- > restartsFor RestartRight children failure = [c,d]
--
-- [Branch Restarts]
--
-- We refer to a restart (strategy) that involves a set of children as a
-- /branch restart/ from now on. The behaviour of branch restarts can be further
-- refined by the 'RestartMode' with which a 'RestartStrategy' is parameterised.
-- The @RestartEach@ mode treats each child sequentially, first stopping the
-- respective child process and then restarting it. Each child is stopped and
-- started fully before moving on to the next, as the following imaginary
-- example demonstrates for children @[a,b,c]@:
--
-- > stop  a
-- > start a
-- > stop  b
-- > start b
-- > stop  c
-- > start c
--
-- By contrast, @RestartInOrder@ will first run through the selected list of
-- children, stopping them. Then, once all the children have been stopped, it
-- will make a second pass, to handle (re)starting them. No child is started
-- until all children have been stopped, as the following imaginary example
-- demonstrates:
--
-- > stop  a
-- > stop  b
-- > stop  c
-- > start a
-- > start b
-- > start c
--
-- Both the previous examples have shown children being stopped and started
-- from left to right, but that is up to the user. The 'RestartMode' data
-- type's constructors take a 'RestartOrder', which determines whether the
-- selected children will be processed from @LeftToRight@ or @RightToLeft@.
--
-- Sometimes it is desireable to stop children in one order and start them
-- in the opposite. This is typically the case when children are in some
-- way dependent on one another, such that restarting them in the wrong order
-- might cause the system to misbehave. For this scenarios, there is another
-- 'RestartMode' that will shut children down in the given order, but then
-- restarts them in the reverse. Using @RestartRevOrder@ mode, if we have
-- children @[a,b,c]@ such that @b@ depends on @a@ and @c@ on @b@, we can stop
-- them in the reverse of their startup order, but restart them the other way
-- around like so:
--
-- > RestartRevOrder RightToLeft
--
-- The effect will be thus:
--
-- > stop  c
-- > stop  b
-- > stop  a
-- > start a
-- > start b
-- > start c
--
-- [Restart Intensity Limits]
--
-- If a child process repeatedly crashes during (or shortly after) starting,
-- it is possible for the supervisor to get stuck in an endless loop of
-- restarts. In order prevent this, each restart strategy is parameterised
-- with a 'RestartLimit' that caps the number of restarts allowed within a
-- specific time period. If the supervisor exceeds this limit, it will stop,
-- terminating all its children (in left-to-right order) and exit with the
-- reason @ExitOther "ReachedMaxRestartIntensity"@.
--
-- The 'MaxRestarts' type is a positive integer, and together with a specified
-- @TimeInterval@ forms the 'RestartLimit' to which the supervisor will adhere.
-- Since a great many children can be restarted in close succession when
-- a /branch restart/ occurs (as a result of @RestartAll@, @RestartLeft@ or
-- @RestartRight@ being triggered), the supervisor will track the operation
-- as a single restart attempt, since otherwise it would likely exceed its
-- maximum restart intensity too quickly.
--
-- [Child Restart and Termination Policies]
--
-- When the supervisor detects that a child has died, the 'RestartPolicy'
-- configured in the child specification is used to determin what to do. If
-- the this is set to @Permanent@, then the child is always restarted.
-- If it is @Temporary@, then the child is never restarted and the child
-- specification is removed from the supervisor. A @Transient@ child will
-- be restarted only if it terminates /abnormally/, otherwise it is left
-- inactive (but its specification is left in place). Finally, an @Intrinsic@
-- child is treated like a @Transient@ one, except that if /this/ kind of child
-- exits /normally/, then the supervisor will also exit normally.
--
-- When the supervisor does terminate a child, the 'ChildTerminationPolicy'
-- provided with the 'ChildSpec' determines how the supervisor should go
-- about doing so. If this is @TerminateImmediately@, then the child will
-- be killed without further notice, which means the child will /not/ have
-- an opportunity to clean up any internal state and/or release any held
-- resources. If the policy is @TerminateTimeout delay@ however, the child
-- will be sent an /exit signal/ instead, i.e., the supervisor will cause
-- the child to exit via @exit childPid ExitShutdown@, and then will wait
-- until the given @delay@ for the child to exit normally. If this does not
-- happen within the given delay, the supervisor will revert to the more
-- aggressive @TerminateImmediately@ policy and try again. Any errors that
-- occur during a timed-out shutdown will be logged, however exit reasons
-- resulting from @TerminateImmediately@ are ignored.
--
-- [Creating Child Specs]
--
-- The 'ToChildStart' typeclass simplifies the process of defining a 'ChildStart'
-- providing three default instances from which a 'ChildStart' datum can be
-- generated. The first, takes a @Closure (Process ())@, where the enclosed
-- action (in the @Process@ monad) is the actual (long running) code that we
-- wish to supervise. In the case of a /managed process/, this is usually the
-- server loop, constructed by evaluating some variant of @ManagedProcess.serve@.
--
-- The other two instances provide a means for starting children without having
-- to provide a @Closure@. Both instances wrap the supplied @Process@ action in
-- some necessary boilerplate code, which handles spawning a new process and
-- communicating its @ProcessId@ to the supervisor. The instance for
-- @Addressable a => SupervisorPid -> Process a@ is special however, since this
-- API is intended for uses where the typical interactions with a process take
-- place via an opaque handle, for which an instance of the @Addressable@
-- typeclass is provided. This latter approach requires the expression which is
-- responsible for yielding the @Addressable@ handle to handling linking the
-- target process with the supervisor, since we have delegated responsibility
-- for spawning the new process and cannot perform the link oepration ourselves.
--
-- [Supervision Trees & Supervisor Termination]
--
-- To create a supervision tree, one simply adds supervisors below one another
-- as children, setting the @childType@ field of their 'ChildSpec' to
-- @Supervisor@ instead of @Worker@. Supervision tree can be arbitrarilly
-- deep, and it is for this reason that we recommend giving a @Supervisor@ child
-- an arbitrary length of time to stop, by setting the delay to @Infinity@
-- or a very large @TimeInterval@.
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Supervisor
  ( -- * Defining and Running a Supervisor
    ChildSpec(..)
  , ChildKey
  , ChildType(..)
  , ChildTerminationPolicy(..)
  , ChildStart(..)
  , RegisteredName(LocalName, CustomRegister)
  , RestartPolicy(..)
--  , ChildRestart(..)
  , ChildRef(..)
  , isRunning
  , isRestarting
  , Child
  , StaticLabel
  , SupervisorPid
  , ToChildStart(..)
  , start
  , run
    -- * Limits and Defaults
  , MaxRestarts
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
  , addChild
  , AddChildResult(..)
  , StartChildResult(..)
  , startChild
  , startNewChild
  , terminateChild
  , TerminateChildResult(..)
  , deleteChild
  , DeleteChildResult(..)
  , restartChild
  , RestartChildResult(..)
    -- * Normative Shutdown
  , shutdown
  , shutdownAndWait
    -- * Queries and Statistics
  , lookupChild
  , listChildren
  , SupervisorStats(..)
  , statistics
    -- * Additional (Misc) Types
  , StartFailure(..)
  , ChildInitFailure(..)
  ) where

import Control.DeepSeq (NFData)
import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.Internal.Primitives hiding (monitor)
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess
  ( handleCall
  , handleInfo
  , reply
  , continue
  , stop
  , stopWith
  , input
  , defaultProcess
  , prioritised
  , InitHandler
  , InitResult(..)
  , ProcessAction
  , ProcessReply
  , ProcessDefinition(..)
  , PrioritisedProcessDefinition(..)
  , Priority(..)
  , DispatchPriority
  , UnhandledMessagePolicy(Drop)
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.UnsafeClient as Unsafe
  ( call
  , cast
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
  ( pserve
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Priority
  ( prioritiseCast_
  , prioritiseCall_
  , prioritiseInfo_
  , setPriority
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted
  ( RestrictedProcess
  , Result
  , RestrictedAction
  , getState
  , putState
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( handleCallIf
  , handleCall
  , handleCast
  , reply
  , continue
  )
-- import Control.Distributed.Process.Platform.ManagedProcess.Server.Unsafe
-- import Control.Distributed.Process.Platform.ManagedProcess.Server
import Control.Distributed.Process.Platform.Service.SystemLog
  ( LogClient
  , LogChan
  , LogText
  , Logger(..)
  )
import qualified Control.Distributed.Process.Platform.Service.SystemLog as Log
import Control.Distributed.Process.Platform.Time
import Control.Exception (SomeException, Exception, throwIO)

import Control.Monad.Error

import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (.>)
  , (^=)
  , (^.)
  )
import Data.Binary
import Data.Foldable (find, foldlM, toList)
import Data.List (foldl')
import qualified Data.List as List (delete)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence
  ( Seq
  , ViewL(EmptyL, (:<))
  , ViewR(EmptyR, (:>))
  , (<|)
  , (|>)
  , (><)
  , filter)
import qualified Data.Sequence as Seq
import Data.Time.Clock
  ( NominalDiffTime
  , UTCTime
  , getCurrentTime
  , diffUTCTime
  )
import Data.Typeable (Typeable)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, filter, init, rem)
#else
import Prelude hiding (filter, init, rem)
#endif

import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- external client/configuration API

newtype MaxRestarts = MaxR { maxNumberOfRestarts :: Int }
  deriving (Typeable, Generic, Show)
instance Binary MaxRestarts where
instance NFData MaxRestarts where

-- | Smart constructor for @MaxRestarts@. The maximum
-- restart count must be a positive integer.
maxRestarts :: Int -> MaxRestarts
maxRestarts r | r >= 0    = MaxR r
              | otherwise = error "MaxR must be >= 0"

-- | A compulsary limit on the number of restarts that a supervisor will
-- tolerate before it terminates all child processes and then itself.
-- If > @MaxRestarts@ occur within the specified @TimeInterval@, termination
-- will occur. This prevents the supervisor from entering an infinite loop of
-- child process terminations and restarts.
--
data RestartLimit =
  RestartLimit
  { maxR :: !MaxRestarts
  , maxT :: !TimeInterval
  }
  deriving (Typeable, Generic, Show)
instance Binary RestartLimit where
instance NFData RestartLimit where

limit :: MaxRestarts -> TimeInterval -> RestartLimit
limit mr ti = RestartLimit mr ti

defaultLimits :: RestartLimit
defaultLimits = limit (MaxR 1) (seconds 1)

data RestartOrder = LeftToRight | RightToLeft
  deriving (Typeable, Generic, Eq, Show)
instance Binary RestartOrder where
instance NFData RestartOrder where

-- TODO: rename these, somehow...
data RestartMode =
    RestartEach     { order :: !RestartOrder }
    {- ^ stop then start each child sequentially, i.e., @foldlM stopThenStart children@ -}
  | RestartInOrder  { order :: !RestartOrder }
    {- ^ stop all children first, then restart them sequentially -}
  | RestartRevOrder { order :: !RestartOrder }
    {- ^ stop all children in the given order, but start them in reverse -}
  deriving (Typeable, Generic, Show, Eq)
instance Binary RestartMode where
instance NFData RestartMode where

data ShutdownMode = SequentialShutdown !RestartOrder
                      | ParallelShutdown
  deriving (Typeable, Generic, Show, Eq)
instance Binary ShutdownMode where
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
-- siblings, which describe's those children's configured position
-- (i.e., insertion order). These latter modes allow one to control the order
-- in which siblings are restarted, and to exclude some siblings from the restart
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
    ChildRunning !ProcessId    -- ^ a reference to the (currently running) child
  | ChildRunningExtra !ProcessId !Message -- ^ also a currently running child, with /extra/ child info
  | ChildRestarting !ProcessId -- ^ a reference to the /old/ (previous) child (now restarting)
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

isRunning :: ChildRef -> Bool
isRunning (ChildRunning _)        = True
isRunning (ChildRunningExtra _ _) = True
isRunning _                       = False

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

-- | Describes when a terminated child process should be restarted.
data RestartPolicy =
    Permanent  -- ^ a permanent child will always be restarted
  | Temporary  -- ^ a temporary child will /never/ be restarted
  | Transient  -- ^ A transient child will be restarted only if it terminates abnormally
  | Intrinsic  -- ^ as 'Transient', but if the child exits normally, the supervisor also exits normally
  deriving (Typeable, Generic, Eq, Show)
instance Binary RestartPolicy where
instance NFData RestartPolicy where

{-
data ChildRestart =
    Restart RestartPolicy  -- ^ restart according to the given policy
  | DelayedRestart RestartPolicy TimeInterval  -- ^ perform a /delayed restart/
  deriving (Typeable, Generic, Eq, Show)
instance Binary ChildRestart where
-}

data ChildTerminationPolicy =
    TerminateTimeout !Delay
  | TerminateImmediately
  deriving (Typeable, Generic, Eq, Show)
instance Binary ChildTerminationPolicy where
instance NFData ChildTerminationPolicy where

data RegisteredName =
    LocalName          !String
  | GlobalName         !String
  | CustomRegister     !(Closure (ProcessId -> Process ()))
  deriving (Typeable, Generic)
instance Binary RegisteredName where
instance NFData RegisteredName where

instance Show RegisteredName where
  show (CustomRegister _) = "Custom Register"
  show (LocalName      n) = n
  show (GlobalName     n) = "global::" ++ n

data ChildStart =
    RunClosure !(Closure (Process ()))
  | CreateHandle !(Closure (SupervisorPid -> Process (ProcessId, Message)))
  | StarterProcess !ProcessId
  deriving (Typeable, Generic, Show)
instance Binary ChildStart where
instance NFData ChildStart  where

-- | Specification for a child process. The child must be uniquely identified
-- by it's @childKey@ within the supervisor. The supervisor will start the child
-- itself, therefore @childRun@ should contain the child process' implementation
-- e.g., if the child is a long running server, this would be the server /loop/,
-- as with e.g., @ManagedProces.start@.
data ChildSpec = ChildSpec {
    childKey     :: !ChildKey
  , childType    :: !ChildType
  , childRestart :: !RestartPolicy
  , childStop    :: !ChildTerminationPolicy
  , childStart   :: !ChildStart
  , childRegName :: !(Maybe RegisteredName)
  } deriving (Typeable, Generic, Show)
instance Binary ChildSpec where
instance NFData ChildSpec where

data ChildInitFailure =
    ChildInitFailure !String
  | ChildInitIgnore
  deriving (Typeable, Generic, Show)
instance Exception ChildInitFailure where

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

type Child = (ChildRef, ChildSpec)
type SupervisorPid = ProcessId

-- | A type that can be converted to a 'ChildStart'.
class ToChildStart a where
  toChildStart :: a -> Process ChildStart

instance ToChildStart (Closure (Process ())) where
  toChildStart = return . RunClosure

instance ToChildStart (Closure (SupervisorPid -> Process (ProcessId, Message))) where
  toChildStart = return . CreateHandle

instance ToChildStart (Process ()) where
  toChildStart proc = do
    starterPid <- spawnLocal $ do
      -- note [linking]: the first time we see the supervisor's pid,
      -- we must link to it, but only once, otherwise we simply waste
      -- time and resources creating duplicate links
      (supervisor, _, sendPidPort) <- expectTriple
      link supervisor
      spawnIt proc supervisor sendPidPort
      tcsProcLoop proc
    return (StarterProcess starterPid)

tcsProcLoop :: Process () -> Process ()
tcsProcLoop p = forever' $ do
  (supervisor, _, sendPidPort) <- expectTriple
  spawnIt p supervisor sendPidPort

spawnIt :: Process ()
        -> ProcessId
        -> SendPort ProcessId
        -> Process ()
spawnIt proc' supervisor sendPidPort = do
  supervisedPid <- spawnLocal $ do
    link supervisor
    self <- getSelfPid
    (proc' `catches` [ Handler $ filterInitFailures supervisor self
                     , Handler $ logFailure supervisor self ])
      `catchesExit` [(\_ m -> handleMessageIf m (== ExitShutdown)
                                                (\_ -> return ()))]
  sendChan sendPidPort supervisedPid

instance (Resolvable a) => ToChildStart (SupervisorPid -> Process a) where
  toChildStart proc = do
    starterPid <- spawnLocal $ do
      -- see note [linking] in the previous instance (above)
      (supervisor, _, sendPidPort) <- expectTriple
      link supervisor
      injectIt proc supervisor sendPidPort >> injectorLoop proc
    return $ StarterProcess starterPid

injectorLoop :: Resolvable a
             => (SupervisorPid -> Process a)
             -> Process ()
injectorLoop p = forever' $ do
  (supervisor, _, sendPidPort) <- expectTriple
  injectIt p supervisor sendPidPort

injectIt :: Resolvable a
         => (SupervisorPid -> Process a)
         -> ProcessId
         -> SendPort ProcessId
         -> Process ()
injectIt proc' supervisor sendPidPort = do
  addr <- proc' supervisor
  mPid <- resolve addr
  case mPid of
    Nothing -> die "UnresolvableAddress"
    Just p  -> sendChan sendPidPort p

expectTriple :: Process (ProcessId, ChildKey, SendPort ProcessId)
expectTriple = expect

-- internal APIs

data DeleteChild = DeleteChild !ChildKey
  deriving (Typeable, Generic)
instance Binary DeleteChild where
instance NFData DeleteChild where

data FindReq = FindReq ChildKey
    deriving (Typeable, Generic)
instance Binary FindReq where
instance NFData FindReq where

data StatsReq = StatsReq
    deriving (Typeable, Generic)
instance Binary StatsReq where
instance NFData StatsReq where

data ListReq = ListReq
    deriving (Typeable, Generic)
instance Binary ListReq where
instance NFData ListReq where

type ImmediateStart = Bool

data AddChildReq = AddChild !ImmediateStart !ChildSpec
    deriving (Typeable, Generic, Show)
instance Binary AddChildReq where
instance NFData AddChildReq where

data AddChildRes = Exists ChildRef | Added State

data AddChildResult =
    ChildAdded         !ChildRef
  | ChildFailedToStart !StartFailure
  deriving (Typeable, Generic, Show, Eq)
instance Binary AddChildResult where
instance NFData AddChildResult where

data StartChildReq = StartChild !ChildKey
  deriving (Typeable, Generic)
instance Binary StartChildReq where
instance NFData StartChildReq where

data StartChildResult =
    ChildStartOk        !ChildRef
  | ChildStartFailed    !StartFailure
  | ChildStartUnknownId
  | ChildStartInitIgnored
  deriving (Typeable, Generic, Show, Eq)
instance Binary StartChildResult where
instance NFData StartChildResult where

data RestartChildReq = RestartChildReq !ChildKey
  deriving (Typeable, Generic, Show, Eq)
instance Binary RestartChildReq where
instance NFData RestartChildReq where

{-
data DelayedRestartReq = DelayedRestartReq !ChildKey !DiedReason
  deriving (Typeable, Generic, Show, Eq)
instance Binary DelayedRestartReq where
-}

data RestartChildResult =
    ChildRestartOk     !ChildRef
  | ChildRestartFailed !StartFailure
  | ChildRestartUnknownId
  | ChildRestartIgnored
  deriving (Typeable, Generic, Show, Eq)

instance Binary RestartChildResult where
instance NFData RestartChildResult where

data TerminateChildReq = TerminateChildReq !ChildKey
  deriving (Typeable, Generic, Show, Eq)
instance Binary TerminateChildReq where
instance NFData TerminateChildReq where

data TerminateChildResult =
    TerminateChildOk
  | TerminateChildUnknownId
  deriving (Typeable, Generic, Show, Eq)
instance Binary TerminateChildResult where
instance NFData TerminateChildResult where

data IgnoreChildReq = IgnoreChildReq !ProcessId
  deriving (Typeable, Generic)
instance Binary IgnoreChildReq where
instance NFData IgnoreChildReq where

type ChildSpecs = Seq Child
type Prefix = ChildSpecs
type Suffix = ChildSpecs

data StatsType = Active | Specified

data LogSink = LogProcess !LogClient | LogChan

instance Logger LogSink where
  logMessage LogChan              = logMessage Log.logChannel
  logMessage (LogProcess client') = logMessage client'

data State = State {
    _specs           :: ChildSpecs
  , _active          :: Map ProcessId ChildKey
  , _strategy        :: RestartStrategy
  , _restartPeriod   :: NominalDiffTime
  , _restarts        :: [UTCTime]
  , _stats           :: SupervisorStats
  , _logger          :: LogSink
  , shutdownStrategy :: ShutdownMode
  }

--------------------------------------------------------------------------------
-- Starting/Running Supervisor                                                --
--------------------------------------------------------------------------------

-- | Start a supervisor (process), running the supplied children and restart
-- strategy.
--
-- > start = spawnLocal . run
--
start :: RestartStrategy -> ShutdownMode -> [ChildSpec] -> Process ProcessId
start rs ss cs = spawnLocal $ run rs ss cs

-- | Run the supplied children using the provided restart strategy.
--
run :: RestartStrategy -> ShutdownMode -> [ChildSpec] -> Process ()
run rs ss specs' = MP.pserve (rs, ss, specs') supInit serverDefinition

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

-- | Obtain statistics about a running supervisor.
--
statistics :: Addressable a => a -> Process (SupervisorStats)
statistics = (flip Unsafe.call) StatsReq

-- | Lookup a possibly supervised child, given its 'ChildKey'.
--
lookupChild :: Addressable a => a -> ChildKey -> Process (Maybe (ChildRef, ChildSpec))
lookupChild addr key = Unsafe.call addr $ FindReq key

-- | List all know (i.e., configured) children.
--
listChildren :: Addressable a => a -> Process [Child]
listChildren addr = Unsafe.call addr ListReq

-- | Add a new child.
--
addChild :: Addressable a => a -> ChildSpec -> Process AddChildResult
addChild addr spec = Unsafe.call addr $ AddChild False spec

-- | Start an existing (configured) child. The 'ChildSpec' must already be
-- present (see 'addChild'), otherwise the operation will fail.
--
startChild :: Addressable a => a -> ChildKey -> Process StartChildResult
startChild addr key = Unsafe.call addr $ StartChild key

-- | Atomically add and start a new child spec. Will fail if a child with
-- the given key is already present.
--
startNewChild :: Addressable a
           => a
           -> ChildSpec
           -> Process AddChildResult
startNewChild addr spec = Unsafe.call addr $ AddChild True spec

-- | Delete a supervised child. The child must already be stopped (see
-- 'terminateChild').
--
deleteChild :: Addressable a => a -> ChildKey -> Process DeleteChildResult
deleteChild addr spec = Unsafe.call addr $ DeleteChild spec

-- | Terminate a running child.
--
terminateChild :: Addressable a
               => a
               -> ChildKey
               -> Process TerminateChildResult
terminateChild sid = Unsafe.call sid . TerminateChildReq

-- | Forcibly restart a running child.
--
restartChild :: Addressable a
             => a
             -> ChildKey
             -> Process RestartChildResult
restartChild sid = Unsafe.call sid . RestartChildReq

-- | Gracefully terminate a running supervisor. Returns immediately if the
-- /address/ cannot be resolved.
--
shutdown :: Resolvable a => a -> Process ()
shutdown sid = do
  mPid <- resolve sid
  case mPid of
    Nothing -> return ()
    Just p  -> exit p ExitShutdown

-- | As 'shutdown', but waits until the supervisor process has exited, at which
-- point the caller can be sure that all children have also stopped. Returns
-- immediately if the /address/ cannot be resolved.
--
shutdownAndWait :: Resolvable a => a -> Process ()
shutdownAndWait sid = do
  mPid <- resolve sid
  case mPid of
    Nothing -> return ()
    Just p  -> withMonitor p $ do
      shutdown p
      receiveWait [ matchIf (\(ProcessMonitorNotification _ p' _) -> p' == p)
                            (\_ -> return ())
                  ]

--------------------------------------------------------------------------------
-- Server Initialisation/Startup                                              --
--------------------------------------------------------------------------------

supInit :: InitHandler (RestartStrategy, ShutdownMode, [ChildSpec]) State
supInit (strategy', shutdown', specs') = do
  logClient <- Log.client
  let client' = case logClient of
                  Nothing -> LogChan
                  Just c  -> LogProcess c
  let initState = ( ( -- as a NominalDiffTime (in seconds)
                      restartPeriod ^= configuredRestartPeriod
                    )
                  . (strategy ^= strategy')
                  . (logger   ^= client')
                  $ emptyState shutdown'
                  )
  -- TODO: should we return Ignore, as per OTP's supervisor, if no child starts?
  (foldlM initChild initState specs' >>= return . (flip InitOk) Infinity)
    `catch` \(e :: SomeException) -> return $ InitStop (show e)
  where
    initChild :: State -> ChildSpec -> Process State
    initChild st ch = tryStartChild ch >>= initialised st ch

    configuredRestartPeriod =
      let maxT' = maxT (intensity strategy')
          tI    = asTimeout maxT'
          tMs   = (fromIntegral tI * (0.000001 :: Float))
      in fromRational (toRational tMs) :: NominalDiffTime

initialised :: State
            -> ChildSpec
            -> Either StartFailure ChildRef
            -> Process State
initialised _     _    (Left  err) = liftIO $ throwIO $ ChildInitFailure (show err)
initialised state spec (Right ref) = do
  mPid <- resolve ref
  case mPid of
    Nothing  -> die $ (childKey spec) ++ ": InvalidChildRef"
    Just pid -> do
      return $ ( (active ^: Map.insert pid chId)
               . (specs  ^: (|> (ref, spec)))
               $ bumpStats Active chType (+1) state
               )
  where chId   = childKey spec
        chType = childType spec

--------------------------------------------------------------------------------
-- Server Definition/State                                                    --
--------------------------------------------------------------------------------

emptyState :: ShutdownMode -> State
emptyState strat = State {
    _specs           = Seq.empty
  , _active          = Map.empty
  , _strategy        = restartAll
  , _restartPeriod   = (fromIntegral (0 :: Integer)) :: NominalDiffTime
  , _restarts        = []
  , _stats           = emptyStats
  , _logger          = LogChan
  , shutdownStrategy = strat
  }

emptyStats :: SupervisorStats
emptyStats = SupervisorStats {
    _children          = 0
  , _workers           = 0
  , _supervisors       = 0
  , _running           = 0
  , _activeSupervisors = 0
  , _activeWorkers     = 0
  , totalRestarts      = 0
--  , avgRestartFrequency   = 0
  }

serverDefinition :: PrioritisedProcessDefinition State
serverDefinition = prioritised processDefinition supPriorities
  where
    supPriorities :: [DispatchPriority State]
    supPriorities = [
        prioritiseCast_ (\(IgnoreChildReq _)                 -> setPriority 100)
      , prioritiseInfo_ (\(ProcessMonitorNotification _ _ _) -> setPriority 99 )
--      , prioritiseCast_ (\(DelayedRestartReq _ _)            -> setPriority 80 )
      , prioritiseCall_ (\(_ :: FindReq) ->
                          (setPriority 10) :: Priority (Maybe (ChildRef, ChildSpec)))
      ]

processDefinition :: ProcessDefinition State
processDefinition =
  defaultProcess {
    apiHandlers = [
       Restricted.handleCast   handleIgnore
       -- adding, removing and (optionally) starting new child specs
     , handleCall              handleTerminateChild
--     , handleCast              handleDelayedRestart
     , Restricted.handleCall   handleDeleteChild
     , Restricted.handleCallIf (input (\(AddChild immediate _) -> not immediate))
                               handleAddChild
     , handleCall              handleStartNewChild
     , handleCall              handleStartChild
     , handleCall              handleRestartChild
       -- stats/info
     , Restricted.handleCall   handleLookupChild
     , Restricted.handleCall   handleListChildren
     , Restricted.handleCall   handleGetStats
     ]
  , infoHandlers = [handleInfo handleMonitorSignal]
  , shutdownHandler = handleShutdown
  , unhandledMessagePolicy = Drop
  } :: ProcessDefinition State

--------------------------------------------------------------------------------
-- API Handlers                                                               --
--------------------------------------------------------------------------------

handleLookupChild :: FindReq
                  -> RestrictedProcess State (Result (Maybe (ChildRef, ChildSpec)))
handleLookupChild (FindReq key) = getState >>= Restricted.reply . findChild key

handleListChildren :: ListReq
                   -> RestrictedProcess State (Result [Child])
handleListChildren _ = getState >>= Restricted.reply . toList . (^. specs)

handleAddChild :: AddChildReq
               -> RestrictedProcess State (Result AddChildResult)
handleAddChild req = getState >>= return . doAddChild req True >>= doReply
  where doReply :: AddChildRes -> RestrictedProcess State (Result AddChildResult)
        doReply (Added  s) = putState s >> Restricted.reply (ChildAdded ChildStopped)
        doReply (Exists e) = Restricted.reply (ChildFailedToStart $ StartFailureDuplicateChild e)

handleIgnore :: IgnoreChildReq
                     -> RestrictedProcess State RestrictedAction
handleIgnore (IgnoreChildReq pid) = do
  {- not only must we take this child out of the `active' field,
     we also delete the child spec if it's restart type is Temporary,
     since restarting Temporary children is dis-allowed -}
  state <- getState
  let (cId, active') =
        Map.updateLookupWithKey (\_ _ -> Nothing) pid $ state ^. active
  case cId of
    Nothing -> Restricted.continue
    Just c  -> do
      putState $ ( (active ^= active')
                 . (resetChildIgnored c)
                 $ state
                 )
      Restricted.continue
  where
    resetChildIgnored :: ChildKey -> State -> State
    resetChildIgnored key state =
      maybe state id $ updateChild key (setChildStopped True) state

handleDeleteChild :: DeleteChild
                  -> RestrictedProcess State (Result DeleteChildResult)
handleDeleteChild (DeleteChild k) = getState >>= handleDelete k
  where
    handleDelete :: ChildKey
                 -> State
                 -> RestrictedProcess State (Result DeleteChildResult)
    handleDelete key state =
      let (prefix, suffix) = Seq.breakl ((== key) . childKey . snd) $ state ^. specs
      in case (Seq.viewl suffix) of
           EmptyL             -> Restricted.reply ChildNotFound
           child :< remaining -> tryDeleteChild child prefix remaining state

    tryDeleteChild (ref, spec) pfx sfx st
      | ref == ChildStopped = do
          putState $ ( (specs ^= pfx >< sfx)
                     $ bumpStats Specified (childType spec) decrement st
                     )
          Restricted.reply ChildDeleted
      | otherwise = Restricted.reply $ ChildNotStopped ref

handleStartChild :: State
                 -> StartChildReq
                 -> Process (ProcessReply StartChildResult State)
handleStartChild state (StartChild key) =
  let child = findChild key state in
  case child of
    Nothing ->
      reply ChildStartUnknownId state
    Just (ref@(ChildRunning _), _) ->
      reply (ChildStartFailed (StartFailureAlreadyRunning ref)) state
    Just (ref@(ChildRunningExtra _ _), _) ->
      reply (ChildStartFailed (StartFailureAlreadyRunning ref)) state
    Just (ref@(ChildRestarting _), _) ->
      reply (ChildStartFailed (StartFailureAlreadyRunning ref)) state
    Just (_, spec) -> do
      started <- doStartChild spec state
      case started of
        Left err         -> reply (ChildStartFailed err) state
        Right (ref, st') -> reply (ChildStartOk ref) st'

handleStartNewChild :: State
                 -> AddChildReq
                 -> Process (ProcessReply AddChildResult State)
handleStartNewChild state req@(AddChild _ spec) =
  let added = doAddChild req False state in
  case added of
    Exists e -> reply (ChildFailedToStart $ StartFailureDuplicateChild e) state
    Added  _ -> attemptStart state spec
  where
    attemptStart st ch = do
      started <- tryStartChild ch
      case started of
        Left err  -> reply (ChildFailedToStart err) $ removeChild spec st -- TODO: document this!
        Right ref -> do
          let st' = ( (specs ^: (|> (ref, spec)))
                    $ bumpStats Specified (childType spec) (+1) st
                    )
            in reply (ChildAdded ref) $ markActive st' ref ch

handleRestartChild :: State
                   -> RestartChildReq
                   -> Process (ProcessReply RestartChildResult State)
handleRestartChild state (RestartChildReq key) =
  let child = findChild key state in
  case child of
    Nothing ->
      reply ChildRestartUnknownId state
    Just (ref@(ChildRunning _), _) ->
      reply (ChildRestartFailed (StartFailureAlreadyRunning ref)) state
    Just (ref@(ChildRunningExtra _ _), _) ->
      reply (ChildRestartFailed (StartFailureAlreadyRunning ref)) state
    Just (ref@(ChildRestarting _), _) ->
      reply (ChildRestartFailed (StartFailureAlreadyRunning ref)) state
    Just (_, spec) -> do
      started <- doStartChild spec state
      case started of
        Left err         -> reply (ChildRestartFailed err) state
        Right (ref, st') -> reply (ChildRestartOk ref) st'

{-
handleDelayedRestart :: State
                     -> DelayedRestartReq
                     -> Process (ProcessAction State)
handleDelayedRestart state (DelayedRestartReq key reason) =
  let child = findChild key state in
  case child of
    Nothing ->
      continue state -- a child could've been terminated and removed by now
    Just ((ChildRestarting pid), spec) -> do
      -- TODO: we ignore the unnecessary .active re-assignments in
      -- tryRestartChild, in order to keep the code simple - it would be good to
      -- clean this up so we don't have to though...
      tryRestartChild pid state (state ^. active) spec reason
-}

handleTerminateChild :: State
                     -> TerminateChildReq
                     -> Process (ProcessReply TerminateChildResult State)
handleTerminateChild state (TerminateChildReq key) =
  let child = findChild key state in
  case child of
    Nothing ->
      reply TerminateChildUnknownId state
    Just (ChildStopped, _) ->
      reply TerminateChildOk state
    Just (ref, spec) ->
      reply TerminateChildOk =<< doTerminateChild ref spec state

handleGetStats :: StatsReq
               -> RestrictedProcess State (Result SupervisorStats)
handleGetStats _ = Restricted.reply . (^. stats) =<< getState

--------------------------------------------------------------------------------
-- Child Monitoring                                                           --
--------------------------------------------------------------------------------

handleMonitorSignal :: State
                    -> ProcessMonitorNotification
                    -> Process (ProcessAction State)
handleMonitorSignal state (ProcessMonitorNotification _ pid reason) = do
  let (cId, active') =
        Map.updateLookupWithKey (\_ _ -> Nothing) pid $ state ^. active
  let mSpec =
        case cId of
          Nothing -> Nothing
          Just c  -> fmap snd $ findChild c state
  case mSpec of
    Nothing   -> continue $ (active ^= active') state
    Just spec -> tryRestart pid state active' spec reason

--------------------------------------------------------------------------------
-- Child Monitoring                                                           --
--------------------------------------------------------------------------------

handleShutdown :: State -> ExitReason -> Process ()
handleShutdown state (ExitOther reason) = terminateChildren state >> die reason
handleShutdown state _                  = terminateChildren state

--------------------------------------------------------------------------------
-- Child Start/Restart Handling                                               --
--------------------------------------------------------------------------------

tryRestart :: ProcessId
           -> State
           -> Map ProcessId ChildKey
           -> ChildSpec
           -> DiedReason
           -> Process (ProcessAction State)
tryRestart pid state active' spec reason = do
  case state ^. strategy of
    RestartOne _ -> tryRestartChild pid state active' spec reason
    strat        -> do
      case (childRestart spec, isNormal reason) of
        (Intrinsic, True) -> stopWith newState ExitNormal
        (Transient, True) -> continue newState
        (Temporary, _)    -> continue removeTemp
        _                 -> tryRestartBranch strat spec reason $ newState
  where
    newState = (active ^= active') state

    removeTemp = removeChild spec $ newState

    isNormal (DiedException _) = False
    isNormal _                 = True

tryRestartBranch :: RestartStrategy
                 -> ChildSpec
                 -> DiedReason
                 -> State
                 -> Process (ProcessAction State)
tryRestartBranch rs sp dr st = -- TODO: use DiedReason for logging...
  let mode' = mode rs
      tree' = case rs of
                RestartAll   _ _ -> childSpecs
                RestartLeft  _ _ -> subTreeL
                RestartRight _ _ -> subTreeR
                _                  -> error "IllegalState"
      proc  = case mode' of
                RestartEach     _ -> stopStart
                RestartInOrder  _ -> restartL
                RestartRevOrder _ -> reverseRestart
      dir'  = order mode' in do
    proc tree' dir'
  where
    stopStart :: ChildSpecs -> RestartOrder -> Process (ProcessAction State)
    stopStart tree order' = do
      let tree' = case order' of
                    LeftToRight -> tree
                    RightToLeft -> Seq.reverse tree
      state <- addRestart activeState
      case state of
        Nothing  -> die errorMaxIntensityReached
        Just st' -> apply (foldlM stopStartIt st' tree')

    reverseRestart :: ChildSpecs
                   -> RestartOrder
                   -> Process (ProcessAction State)
    reverseRestart tree LeftToRight = restartL tree RightToLeft -- force re-order
    reverseRestart tree dir@(RightToLeft) = restartL (Seq.reverse tree) dir

    -- TODO: rename me for heaven's sake - this ISN'T a left biased traversal after all!
    restartL :: ChildSpecs -> RestartOrder -> Process (ProcessAction State)
    restartL tree ro = do
      let rev   = (ro == RightToLeft)
      let tree' = case rev of
                    False -> tree
                    True  -> Seq.reverse tree
      state <- addRestart activeState
      case state of
        Nothing -> die errorMaxIntensityReached
        Just st' -> foldlM stopIt st' tree >>= \s -> do
                     apply $ foldlM startIt s tree'

    stopStartIt :: State -> Child -> Process State
    stopStartIt s ch@(cr, cs) = doTerminateChild cr cs s >>= (flip startIt) ch

    stopIt :: State -> Child -> Process State
    stopIt s (cr, cs) = doTerminateChild cr cs s

    startIt :: State -> Child -> Process State
    startIt s (_, cs)
      | isTemporary (childRestart cs) = return $ removeChild cs s
      | otherwise                     = ensureActive cs =<< doStartChild cs s

    -- Note that ensureActive will kill this (supervisor) process if
    -- doStartChild fails, simply because the /only/ failure that can
    -- come out of that function (as `Left err') is *bad closure* and
    -- that should have either been picked up during init (i.e., caused
    -- the super to refuse to start) or been removed during `startChild'
    -- or later on. Any other kind of failure will crop up (once we've
    -- finished the restart sequence) as a monitor signal.
    ensureActive :: ChildSpec
                 -> Either StartFailure (ChildRef, State)
                 -> Process State
    ensureActive cs it
      | (Right (ref, st')) <- it = return $ markActive st' ref cs
      | (Left err) <- it = die $ ExitOther $ (childKey cs) ++ ": " ++ (show err)
      | otherwise = error "IllegalState"

    apply :: (Process State) -> Process (ProcessAction State)
    apply proc = do
      catchExit (proc >>= continue) (\(_ :: ProcessId) -> stop)

    activeState = maybe st id $ updateChild (childKey sp)
                                            (setChildStopped False) st

    subTreeL :: ChildSpecs
    subTreeL =
      let (prefix, suffix) = splitTree Seq.breakl
      in case (Seq.viewl suffix) of
           child :< _ -> prefix |> child
           EmptyL     -> prefix

    subTreeR :: ChildSpecs
    subTreeR =
      let (prefix, suffix) = splitTree Seq.breakr
      in case (Seq.viewr suffix) of
           _ :> child -> child <| prefix
           EmptyR     -> prefix

    splitTree splitWith = splitWith ((== childKey sp) . childKey . snd) childSpecs

    childSpecs :: ChildSpecs
    childSpecs =
      let cs  = activeState ^. specs
          ck  = childKey sp
          rs' = childRestart sp
      in case (isTransient rs', isTemporary rs', dr) of
           (True, _, DiedNormal) -> filter ((/= ck) . childKey . snd) cs
           (_, True, _)          -> filter ((/= ck) . childKey . snd) cs
           _                     -> cs

{-  restartParallel :: ChildSpecs
                    -> RestartOrder
                    -> Process (ProcessAction State)
    restartParallel tree order = do
      liftIO $ putStrLn "handling parallel restart"
      let tree'    = case order of
                       LeftToRight -> tree
                       RightToLeft -> Seq.reverse tree

      -- TODO: THIS IS INCORRECT... currently (below), we terminate
      -- the branch in parallel, but wait on all the exits and then
      -- restart sequentially (based on 'order'). That's not what the
      -- 'RestartParallel' mode advertised, but more importantly, it's
      -- not clear what the semantics for error handling (viz restart errors)
      -- should actually be.

      asyncs <- forM (toList tree') $ \ch -> async $ asyncTerminate ch
      (_errs, st') <- foldlM collectExits ([], activeState) asyncs
      -- TODO: report errs
      apply $ foldlM startIt st' tree'
      where
        asyncTerminate :: Child -> Process (Maybe (ChildKey, ProcessId))
        asyncTerminate (cr, cs) = do
          mPid <- resolve cr
          case mPid of
            Nothing  -> return Nothing
            Just pid -> do
              void $ doTerminateChild cr cs activeState
              return $ Just (childKey cs, pid)

        collectExits :: ([ExitReason], State)
                     -> Async (Maybe (ChildKey, ProcessId))
                     -> Process ([ExitReason], State)
        collectExits (errs, state) hAsync = do
          -- we perform a blocking wait on each handle, since we'll
          -- always wait until the last shutdown has occurred anyway
          asyncResult <- wait hAsync
          let res = mergeState asyncResult state
          case res of
            Left err -> return ((err:errs), state)
            Right st -> return (errs, st)

        mergeState :: AsyncResult (Maybe (ChildKey, ProcessId))
                   -> State
                   -> Either ExitReason State
        mergeState (AsyncDone Nothing)           state = Right state
        mergeState (AsyncDone (Just (key, pid))) state = Right $ mergeIt key pid state
        mergeState (AsyncFailed r)               _     = Left $ ExitOther (show r)
        mergeState (AsyncLinkFailed r)           _     = Left $ ExitOther (show r)
        mergeState _                             _     = Left $ ExitOther "IllegalState"

        mergeIt :: ChildKey -> ProcessId -> State -> State
        mergeIt key pid state =
          -- TODO: lookup the old ref -> pid and delete from the active map
          ( (active ^: Map.delete pid)
          $ maybe state id (updateChild key (setChildStopped False) state)
          )
    -}

tryRestartChild :: ProcessId
                -> State
                -> Map ProcessId ChildKey
                -> ChildSpec
                -> DiedReason
                -> Process (ProcessAction State)
tryRestartChild pid st active' spec reason
  | DiedNormal <- reason
  , True       <- isTransient (childRestart spec) = continue childDown
  | True       <- isTemporary (childRestart spec) = continue childRemoved
  | DiedNormal <- reason
  , True       <- isIntrinsic (childRestart spec) = stopWith updateStopped ExitNormal
  | otherwise     = continue =<< doRestartChild pid spec reason st
  where
    childDown     = (active ^= active') $ updateStopped
    childRemoved  = (active ^= active') $ removeChild spec st
    updateStopped = maybe st id $ updateChild chKey (setChildStopped False) st
    chKey         = childKey spec

doRestartChild :: ProcessId -> ChildSpec -> DiedReason -> State -> Process State
doRestartChild _ spec _ state = do -- TODO: use ProcessId and DiedReason to log
  state' <- addRestart state
  case state' of
    Nothing -> die errorMaxIntensityReached
--      case restartPolicy of
--        Restart _            -> die errorMaxIntensityReached
--        DelayedRestart _ del -> doRestartDelay oldPid del spec reason state
    Just st -> do
      start' <- doStartChild spec st
      case start' of
        Right (ref, st') -> do
          return $ markActive st' ref spec
        Left _ -> do -- TODO: handle this by policy
          -- All child failures are handled via monitor signals, apart from
          -- BadClosure, which comes back from doStartChild as (Left err).
          -- Since we cannot recover from that, there's no point in trying
          -- to start this child again (as the closure will never resolve),
          -- so we remove the child forthwith. We should provide a policy
          -- for handling this situation though...
          return $ ( (active ^: Map.filter (/= chKey))
                   . (bumpStats Active chType decrement)
                   . (bumpStats Specified chType decrement)
                   $ removeChild spec st
                   )
  where
    chKey  = childKey spec
    chType = childType spec

{-
doRestartDelay :: ProcessId
               -> TimeInterval
               -> ChildSpec
               -> DiedReason
               -> State
               -> Process State
doRestartDelay oldPid rDelay spec reason state = do
  self <- getSelfPid
  _ <- runAfter rDelay $ MP.cast self (DelayedRestartReq (childKey spec) reason)
  return $ ( (active ^: Map.filter (/= chKey))
           . (bumpStats Active chType decrement)
           $ maybe state id (updateChild chKey (setChildRestarting oldPid) state)
           )
  where
    chKey  = childKey spec
    chType = childType spec
-}

addRestart :: State -> Process (Maybe State)
addRestart state = do
  now <- liftIO $ getCurrentTime
  let acc = foldl' (accRestarts now) [] (now:restarted)
  case length acc of
    n | n > maxAttempts -> return Nothing
    _                   -> return $ Just $ (restarts ^= acc) $ state
  where
    maxAttempts  = maxNumberOfRestarts $ maxR $ maxIntensity
    slot         = state ^. restartPeriod
    restarted    = state ^. restarts
    maxIntensity = state ^. strategy .> restartIntensity

    accRestarts :: UTCTime -> [UTCTime] -> UTCTime -> [UTCTime]
    accRestarts now' acc r =
      let diff = diffUTCTime now' r in
      if diff > slot then acc else (r:acc)

doStartChild :: ChildSpec
             -> State
             -> Process (Either StartFailure (ChildRef, State))
doStartChild spec st = do
  restart <- tryStartChild spec
  case restart of
    Left f  -> return $ Left f
    Right p -> do
      let mState = updateChild chKey (chRunning p) st
      case mState of
        -- TODO: better error message if the child is unrecognised
        Nothing -> die "InternalError"
        Just s' -> return $ Right $ (p, markActive s' p spec)
  where
    chKey = childKey spec

    chRunning :: ChildRef -> Child -> Prefix -> Suffix -> State -> Maybe State
    chRunning newRef (_, chSpec) prefix suffix st' =
      Just $ ( (specs ^= prefix >< ((newRef, chSpec) <| suffix))
             $ bumpStats Active (childType spec) (+1) st'
             )

tryStartChild :: ChildSpec
              -> Process (Either StartFailure ChildRef)
tryStartChild ChildSpec{..} =
    case childStart of
      RunClosure proc -> do
        -- TODO: cache your closures!!!
        mProc <- catch (unClosure proc >>= return . Right)
                       (\(e :: SomeException) -> return $ Left (show e))
        case mProc of
          Left err -> logStartFailure $ StartFailureBadClosure err
          Right p  -> wrapClosure childRegName p >>= return . Right
      CreateHandle fn -> do
        mFn <- catch (unClosure fn >>= return . Right)
                     (\(e :: SomeException) -> return $ Left (show e))
        case mFn of
          Left err  -> logStartFailure $ StartFailureBadClosure err
          Right fn' -> do
            wrapHandle childRegName fn' >>= return . Right
      StarterProcess restarterPid ->
          wrapRestarterProcess childRegName restarterPid
  where
    logStartFailure sf = do
      sup <- getSelfPid
      logEntry Log.error $ mkReport "Child Start Error" sup "noproc" (show sf)
      return $ Left sf

    wrapClosure :: Maybe RegisteredName
                -> Process ()
                -> Process ChildRef
    wrapClosure regName proc = do
      supervisor <- getSelfPid
      pid <- spawnLocal $ do
        self <- getSelfPid
        link supervisor -- die if our parent dies
        maybeRegister regName self
        () <- expect    -- wait for a start signal (pid is still private)
        -- we translate `ExitShutdown' into a /normal/ exit
        (proc `catches` [ Handler $ filterInitFailures supervisor self
                        , Handler $ logFailure supervisor self ])
          `catchesExit` [
            (\_ m -> handleMessageIf m (== ExitShutdown)
                                       (\_ -> return ()))]
      void $ monitor pid
      send pid ()
      return $ ChildRunning pid

    wrapHandle :: Maybe RegisteredName
               -> (SupervisorPid -> Process (ProcessId, Message))
               -> Process ChildRef
    wrapHandle regName proc = do
      super <- getSelfPid
      (pid, msg) <- proc super
      maybeRegister regName pid
      return $ ChildRunningExtra pid msg

    wrapRestarterProcess :: Maybe RegisteredName
                         -> ProcessId
                         -> Process (Either StartFailure ChildRef)
    wrapRestarterProcess regName restarterPid = do
      selfPid <- getSelfPid
      (sendPid, recvPid) <- newChan
      ref <- monitor restarterPid
      send restarterPid (selfPid, childKey, sendPid)
      ePid <- receiveWait [
                -- TODO: tighten up this contract to correct for erroneous mail
                matchChan recvPid (\(pid :: ProcessId) -> return $ Right pid)
              , matchIf (\(ProcessMonitorNotification mref _ dr) ->
                           mref == ref && dr /= DiedNormal)
                        (\(ProcessMonitorNotification _ _ dr) ->
                           return $ Left dr)
              ] `finally` (unmonitor ref)
      case ePid of
        Right pid -> do
          maybeRegister regName pid
          void $ monitor pid
          return $ Right $ ChildRunning pid
        Left dr -> return $ Left $ StartFailureDied dr


    maybeRegister :: Maybe RegisteredName -> ProcessId -> Process ()
    maybeRegister Nothing                         _     = return ()
    maybeRegister (Just (LocalName n))            pid   = register n pid
    maybeRegister (Just (GlobalName _))           _     = return ()
    maybeRegister (Just (CustomRegister clj))     pid   = do
        -- TODO: cache your closures!!!
        mProc <- catch (unClosure clj >>= return . Right)
                       (\(e :: SomeException) -> return $ Left (show e))
        case mProc of
          Left err -> die $ ExitOther (show err)
          Right p  -> p pid

filterInitFailures :: ProcessId
                   -> ProcessId
                   -> ChildInitFailure
                   -> Process ()
filterInitFailures sup pid ex = do
  case ex of
    ChildInitFailure _ -> liftIO $ throwIO ex
    ChildInitIgnore    -> Unsafe.cast sup $ IgnoreChildReq pid

--------------------------------------------------------------------------------
-- Child Termination/Shutdown                                                 --
--------------------------------------------------------------------------------

terminateChildren :: State -> Process ()
terminateChildren state = do
  case (shutdownStrategy state) of
    ParallelShutdown -> do
      let allChildren = toList $ state ^. specs
      pids <- forM allChildren $ \ch -> do
        pid <- spawnLocal $ void $ syncTerminate ch $ (active ^= Map.empty) state
        void $ monitor pid
        return pid
      void $ collectExits [] pids
      -- TODO: report errs???
    SequentialShutdown ord -> do
      let specs'      = state ^. specs
      let allChildren = case ord of
                          RightToLeft -> Seq.reverse specs'
                          LeftToRight -> specs'
      void $ foldlM (flip syncTerminate) state (toList allChildren)
  where
    syncTerminate :: Child -> State -> Process State
    syncTerminate (cr, cs) state' = doTerminateChild cr cs state'

    collectExits :: [DiedReason]
                 -> [ProcessId]
                 -> Process [DiedReason]
    collectExits errors []   = return errors
    collectExits errors pids = do
      (pid, reason) <- receiveWait [
          match (\(ProcessMonitorNotification _ pid' reason') -> do
                    return (pid', reason'))
        ]
      let remaining = List.delete pid pids
      case reason of
        DiedNormal -> collectExits errors          remaining
        _          -> collectExits (reason:errors) remaining

doTerminateChild :: ChildRef -> ChildSpec -> State -> Process State
doTerminateChild ref spec state = do
  mPid <- resolve ref
  case mPid of
    Nothing  -> return state -- an already dead child is not an error
    Just pid -> do
      stopped <- childShutdown (childStop spec) pid state
      state' <- shutdownComplete state pid stopped
      return $ ( (active ^: Map.delete pid)
               $ state'
               )
  where
    shutdownComplete :: State -> ProcessId -> DiedReason -> Process State
    shutdownComplete _      _   DiedNormal        = return $ updateStopped
    shutdownComplete state' pid (r :: DiedReason) = do
      logShutdown (state' ^. logger) chKey pid r >> return state'

    chKey         = childKey spec
    updateStopped = maybe state id $ updateChild chKey (setChildStopped False) state

childShutdown :: ChildTerminationPolicy
              -> ProcessId
              -> State
              -> Process DiedReason
childShutdown policy pid st = do
  case policy of
    (TerminateTimeout t) -> exit pid ExitShutdown >> await pid t st
    -- we ignore DiedReason for brutal kills
    TerminateImmediately -> do
      kill pid "TerminatedBySupervisor"
      void $ await pid Infinity st
      return DiedNormal
  where
    await :: ProcessId -> Delay -> State -> Process DiedReason
    await pid' delay state = do
      let monitored = (Map.member pid' $ state ^. active)
      let recv = case delay of
                   Infinity -> receiveWait (matches pid') >>= return . Just
                   NoDelay  -> receiveTimeout 0 (matches pid')
                   Delay t  -> receiveTimeout (asTimeout t) (matches pid')
      -- we set up an additional monitor here, since child shutdown can occur
      -- during a restart which was triggered by the /old/ monitor signal
      let recv' =  if monitored then recv else withMonitor pid' recv
      recv' >>= maybe (childShutdown TerminateImmediately pid' state) return

    matches :: ProcessId -> [Match DiedReason]
    matches p = [
          matchIf (\(ProcessMonitorNotification _ p' _) -> p == p')
                  (\(ProcessMonitorNotification _ _ r) -> return r)
        ]

--------------------------------------------------------------------------------
-- Loging/Reporting                                                          --
--------------------------------------------------------------------------------

errorMaxIntensityReached :: ExitReason
errorMaxIntensityReached = ExitOther "ReachedMaxRestartIntensity"

logShutdown :: LogSink -> ChildKey -> ProcessId -> DiedReason -> Process ()
logShutdown log' child pid reason = do
    self <- getSelfPid
    Log.info log' $ mkReport banner self (show pid) shutdownReason
  where
    banner         = "Child Shutdown Complete"
    shutdownReason = (show reason) ++ ", child-key: " ++ child

logFailure :: ProcessId -> ProcessId -> SomeException -> Process ()
logFailure sup pid ex = do
  logEntry Log.notice $ mkReport "Detected Child Exit" sup (show pid) (show ex)
  liftIO $ throwIO ex

logEntry :: (LogChan -> LogText -> Process ()) -> String -> Process ()
logEntry lg = Log.report lg Log.logChannel

mkReport :: String -> ProcessId -> String -> String -> String
mkReport b s c r = foldl' (\x xs -> xs ++ " " ++ x) "" items
  where
    items :: [String]
    items = [ "[" ++ s' ++ "]" | s' <- [ b
                                       , "supervisor: " ++ show s
                                       , "child: " ++ c
                                       , "reason: " ++ r] ]

--------------------------------------------------------------------------------
-- Accessors and State/Stats Utilities                                        --
--------------------------------------------------------------------------------

type Ignored = Bool

-- TODO: test that setChildStopped does not re-order the 'specs sequence

setChildStopped ::  Ignored -> Child -> Prefix -> Suffix -> State -> Maybe State
setChildStopped ignored child prefix remaining st =
  let spec   = snd child
      rType  = childRestart spec
      newRef = if ignored then ChildStartIgnored else ChildStopped
  in case isTemporary rType of
    True  -> Just $ (specs ^= prefix >< remaining) $ st
    False -> Just $ (specs ^= prefix >< ((newRef, spec) <| remaining)) st

{-
setChildRestarting :: ProcessId -> Child -> Prefix -> Suffix -> State -> Maybe State
setChildRestarting oldPid child prefix remaining st =
  let spec   = snd child
      newRef = ChildRestarting oldPid
  in Just $ (specs ^= prefix >< ((newRef, spec) <| remaining)) st
-}

doAddChild :: AddChildReq -> Bool -> State -> AddChildRes
doAddChild (AddChild _ spec) update st =
  let chType = childType spec
  in case (findChild (childKey spec) st) of
       Just (ref, _) -> Exists ref
       Nothing ->
         case update of
           True  -> Added $ ( (specs ^: (|> (ChildStopped, spec)))
                           $ bumpStats Specified chType (+1) st
                           )
           False -> Added st

updateChild :: ChildKey
            -> (Child -> Prefix -> Suffix -> State -> Maybe State)
            -> State
            -> Maybe State
updateChild key updateFn state =
  let (prefix, suffix) = Seq.breakl ((== key) . childKey . snd) $ state ^. specs
  in case (Seq.viewl suffix) of
    EmptyL             -> Nothing
    child :< remaining -> updateFn child prefix remaining state

removeChild :: ChildSpec -> State -> State
removeChild spec state =
  let k = childKey spec
  in specs ^: filter ((/= k) . childKey . snd) $ state

-- DO NOT call this function unless you've verified the ChildRef first.
markActive :: State -> ChildRef -> ChildSpec -> State
markActive state ref spec =
  case ref of
    ChildRunning (pid :: ProcessId) -> inserted pid
    ChildRunningExtra pid _         -> inserted pid
    _                               -> error $ "InternalError"
  where
    inserted pid' = active ^: Map.insert pid' (childKey spec) $ state

decrement :: Int -> Int
decrement n = n - 1

-- this is O(n) in the worst case, which is a bit naff, but we
-- can optimise it later with a different data structure, if required
findChild :: ChildKey -> State -> Maybe (ChildRef, ChildSpec)
findChild key st = find ((== key) . childKey . snd) $ st ^. specs

bumpStats :: StatsType -> ChildType -> (Int -> Int) -> State -> State
bumpStats Specified Supervisor fn st = (bump fn) . (stats .> supervisors ^: fn) $ st
bumpStats Specified Worker     fn st = (bump fn) . (stats .> workers ^: fn) $ st
bumpStats Active    Worker     fn st = (stats .> running ^: fn) . (stats .> activeWorkers ^: fn) $ st
bumpStats Active    Supervisor fn st = (stats .> running ^: fn) . (stats .> activeSupervisors ^: fn) $ st

bump :: (Int -> Int) -> State -> State
bump with' = stats .> children ^: with'

isTemporary :: RestartPolicy -> Bool
isTemporary = (== Temporary)

isTransient :: RestartPolicy -> Bool
isTransient = (== Transient)

isIntrinsic :: RestartPolicy -> Bool
isIntrinsic = (== Intrinsic)

active :: Accessor State (Map ProcessId ChildKey)
active = accessor _active (\act' st -> st { _active = act' })

strategy :: Accessor State RestartStrategy
strategy = accessor _strategy (\s st -> st { _strategy = s })

restartIntensity :: Accessor RestartStrategy RestartLimit
restartIntensity = accessor intensity (\i l -> l { intensity = i })

restartPeriod :: Accessor State NominalDiffTime
restartPeriod = accessor _restartPeriod (\p st -> st { _restartPeriod = p })

restarts :: Accessor State [UTCTime]
restarts = accessor _restarts (\r st -> st { _restarts = r })

specs :: Accessor State ChildSpecs
specs = accessor _specs (\sp' st -> st { _specs = sp' })

stats :: Accessor State SupervisorStats
stats = accessor _stats (\st' st -> st { _stats = st' })

logger :: Accessor State LogSink
logger = accessor _logger (\l st -> st { _logger = l })

children :: Accessor SupervisorStats Int
children = accessor _children (\c st -> st { _children = c })

workers :: Accessor SupervisorStats Int
workers = accessor _workers (\c st -> st { _workers = c })

running :: Accessor SupervisorStats Int
running = accessor _running (\r st -> st { _running = r })

supervisors :: Accessor SupervisorStats Int
supervisors = accessor _supervisors (\c st -> st { _supervisors = c })

activeWorkers :: Accessor SupervisorStats Int
activeWorkers = accessor _activeWorkers (\c st -> st { _activeWorkers = c })

activeSupervisors :: Accessor SupervisorStats Int
activeSupervisors = accessor _activeSupervisors (\c st -> st { _activeSupervisors = c })
