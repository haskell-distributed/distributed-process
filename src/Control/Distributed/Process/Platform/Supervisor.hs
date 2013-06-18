{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE PatternGuards              #-}

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
-- stops, it will terminate its children in reverse (i.e., from
-- right-to-left of insertion order). Child specs can be added to the supervisor
-- after it has started, either on the left or right of the existing list of
-- children.
--
-- When a supervisor exits (for any reason), it will always attempt to terminate
-- all its children, which it does from left-to-right (in insertion order). When
-- the supervisor spawns its child processes, they are always linked to thier
-- parent (i.e., the supervisor), therefore even if the supervisor is terminated
-- abruptly by an asynchronous exception, the children will still be taken down
-- with it, though somewhat less ceremoniously in that case.
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
-- in insertion (i.e., startup) order. The failing child is /always/ included in
-- the /branch/ to be restarted, unless it is a @Temporary@ child, in which case
-- it will be removed from the supervisor and never restarted (see
-- 'RestartPolicy' for details).
--
-- For a hypothetical set of children @a@ through @d@, the following pseudocode
-- demonstrates how the restart strategies work.
--
-- > let children = [a..d]
-- > let failure = c
-- > restartsFor RestartOne children failure   = [c]
-- > restartsFor RestartAll children failure   = [a,b,c,d]
-- > restartsFor RestartLeft children failure  = [a,b,c]
-- > restartsFor RestartRight children failure = [a,b,c,d]
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
-- [Supervision Trees]
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
  , RegisteredName(LocalName)
  , RestartPolicy(..)
--  , ChildRestart(..)
  , ChildRef(..)
  , isRunning
  , isRestarting
  , Child
  , StaticLabel
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
  , restartOne
  , restartAll
  , restartLeft
  , restartRight
    -- * Adding and Removing Children
  , addChild
  , AddChildResult(..)
  , startChild
  , terminateChild
  , deleteChild
  , DeleteChildResult(..)
  , restartChild
  , RestartChildResult(..)
    -- * Queries and Statistics
  , lookupChild
  , listChildren
  , SupervisorStats(..)
  , statistics
    -- * Additional (Misc) Types
  , StartFailure(..)
  , ChildInitFailure(..)
  ) where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.Internal.Primitives hiding (monitor)
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess
  ( call
  , handleCall
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
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
  ( pserve
  , cast
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
import Data.Maybe (catMaybes)
import Data.Map (Map)
import qualified Data.Map.Strict as Map -- TODO: use Data.Map.Strict
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
import Prelude hiding (filter, init, rem)

import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- external client/configuration API

newtype MaxRestarts = MaxR { maxNumberOfRestarts :: Int }
  deriving (Typeable, Generic, Show)
instance Binary MaxRestarts where

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

limit :: MaxRestarts -> TimeInterval -> RestartLimit
limit mr ti = RestartLimit mr ti

defaultLimits :: RestartLimit
defaultLimits = limit (MaxR 1) (seconds 1)

data RestartOrder = LeftToRight | RightToLeft
  deriving (Typeable, Generic, Eq, Show)
instance Binary RestartOrder where

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

-- | Strategy used by a supervisor to handle child restarts, whether due to
-- unexpected child failure or explicit restart requests from a client.
--
-- Some terminology: We refer to child processes managed by the same supervisor
-- as /siblings/. When restarting a child process, the 'RestartNone' policy
-- indicates that sibling processes should be left alone, whilst the 'RestartAll'
-- policy will cause /all/ children to be restarted (in the same order they were
-- started). ************************************************************************
-- The other two restart strategies refer to /prior/ and /subsequent/
-- siblings, which describe's those children's configured position
-- (i.e., insertion order). These latter modes allow one to control the order
-- in which siblings are restarted, and to exclude some siblings from the restart
-- without having to resort to grouping them using a child supervisor.
--
data RestartStrategy =
    RestartOne
    { intensity :: !RestartLimit } -- ^ restart only the failed child process
  | RestartAll
    { intensity :: !RestartLimit
    , mode      :: !RestartMode
    } -- ^ also restart all siblings
  | RestartLeft
    { intensity :: !RestartLimit
    , mode      :: !RestartMode
    } -- ^ restart prior siblings (i.e., prior /start order/)
  | RestartRight
    { intensity :: !RestartLimit
    , mode      :: !RestartMode
    } -- ^ restart subsequent siblings (i.e., subsequent /start order/)
  deriving (Typeable, Generic, Show)
instance Binary RestartStrategy where

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
  | ChildRestarting !ProcessId -- ^ a reference to the /old/ (previous) child, which is now restarting
  | ChildStopped               -- ^ indicates the child is not currently running
  | ChildStartIgnored          -- ^ a non-temporary child exited with 'ChildInitIgnore'
  deriving (Typeable, Generic, Eq, Show)
instance Binary ChildRef where

isRunning :: ChildRef -> Bool
isRunning (ChildRunning _) = True
isRunning _                = False

isRestarting :: ChildRef -> Bool
isRestarting (ChildRestarting _) = True
isRestarting _                   = False

-- these look a bit odd, but we basically want to avoid resolving
-- or sending to (ChildRestarting oldPid)
instance Addressable ChildRef where
  sendTo (ChildRunning addr) = sendTo addr
  sendTo _                   = error "invalid address for child process"

  resolve (ChildRunning pid) = resolve pid
  resolve _                  = return Nothing

-- | Specifies whether the child is another supervisor, or a worker.
data ChildType = Worker | Supervisor
  deriving (Typeable, Generic, Show, Eq)
instance Binary ChildType where

-- | Describes when a terminated child process should be restarted.
data RestartPolicy =
    Permanent  -- ^ a permanent child will always be restarted
  | Temporary  -- ^ a temporary child will /never/ be restarted
  | Transient  -- ^ a transient child will be restarted only if it terminates abnormally
  | Intrinsic  -- ^ as 'Transient', but if the child exits normally, the supervisor also exits normally
  deriving (Typeable, Generic, Eq, Show)
instance Binary RestartPolicy where

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

data RegisteredName = LocalName !String | GlobalName !String
  deriving (Typeable, Generic, Show, Eq)
instance Binary RegisteredName where

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
  , childRun     :: !(Closure (Process ()))
  , childRegName :: !(Maybe RegisteredName)
  } deriving (Typeable, Generic, Show)
instance Binary ChildSpec where

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

-- | The result of a call to 'removeChild'.
data DeleteChildResult =
    ChildDeleted              -- ^ the child specification was successfully removed
  | ChildNotFound             -- ^ the child specification was not found
  | ChildNotStopped !ChildRef -- ^ the child was not removed, as it was not stopped.
  deriving (Typeable, Generic, Show, Eq)
instance Binary DeleteChildResult where

type Child = (ChildRef, ChildSpec)

-- internal APIs

data DeleteChild = DeleteChild !ChildKey
  deriving (Typeable, Generic)
instance Binary DeleteChild where

data FindReq = FindReq ChildKey
    deriving (Typeable, Generic)
instance Binary FindReq where

data StatsReq = StatsReq
    deriving (Typeable, Generic)
instance Binary StatsReq where

data ListReq = ListReq
    deriving (Typeable, Generic)
instance Binary ListReq where

type ImmediateStart = Bool

data AddChildReq = AddChild !ImmediateStart !ChildSpec
    deriving (Typeable, Generic, Show)
instance Binary AddChildReq where

data AddChildRes = Exists ChildRef | Added State

data AddChildResult =
    ChildAdded         !ChildRef
  | ChildFailedToStart !StartFailure
  deriving (Typeable, Generic, Show, Eq)
instance Binary AddChildResult where

data RestartChildReq = RestartChildReq !ChildKey
  deriving (Typeable, Generic, Show, Eq)
instance Binary RestartChildReq where

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

data TerminateChildReq = TerminateChildReq !ChildKey
  deriving (Typeable, Generic, Show, Eq)
instance Binary TerminateChildReq where

data TerminateChildResult =
    TerminateChildOk
  | TerminateChildUnknownId
  deriving (Typeable, Generic, Show, Eq)
instance Binary TerminateChildResult where

data IgnoreChildReq = IgnoreChildReq !ProcessId
  deriving (Typeable, Generic)
instance Binary IgnoreChildReq where

type ChildSpecs = Seq Child
type Prefix = ChildSpecs
type Suffix = ChildSpecs

data StatsType = Active | Specified

data State = State {
    _specs         :: ChildSpecs
  , _active        :: Map ProcessId ChildKey
  , _strategy      :: RestartStrategy
  , _restartPeriod :: NominalDiffTime
  , _restarts      :: [UTCTime]
  , _stats         :: SupervisorStats
  }

--------------------------------------------------------------------------------
-- Starting/Running Supervisor                                                --
--------------------------------------------------------------------------------

-- | Start a supervisor (process), running the supplied children and restart
-- strategy.
--
-- > start = spawnLocal . run
--
start :: RestartStrategy -> [ChildSpec] -> Process ProcessId
start s cs = spawnLocal $ run s cs

-- | Run the supplied children using the provided restart strategy.
--
run :: RestartStrategy -> [ChildSpec] -> Process ()
run strategy' specs' = MP.pserve (strategy', specs') supInit serverDefinition

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

statistics :: Addressable a => a -> Process (SupervisorStats)
statistics = (flip call) StatsReq

lookupChild :: Addressable a => a -> ChildKey -> Process (Maybe (ChildRef, ChildSpec))
lookupChild addr key = call addr $ FindReq key

listChildren :: Addressable a => a -> Process [Child]
listChildren addr = call addr ListReq

addChild :: Addressable a => a -> ChildSpec -> Process AddChildResult
addChild addr spec = call addr $ AddChild False spec

startChild :: Addressable a
           => a
           -> ChildSpec
           -> Process AddChildResult
startChild addr spec = call addr $ AddChild True spec

deleteChild :: Addressable a => a -> ChildKey -> Process DeleteChildResult
deleteChild addr spec = call addr $ DeleteChild spec

terminateChild :: Addressable a
               => a
               -> ChildKey
               -> Process TerminateChildResult
terminateChild sid = call sid . TerminateChildReq

restartChild :: Addressable a
             => a
             -> ChildKey
             -> Process RestartChildResult
restartChild sid = call sid . RestartChildReq

--------------------------------------------------------------------------------
-- Server Initialisation/Startup                                              --
--------------------------------------------------------------------------------

supInit :: InitHandler (RestartStrategy, [ChildSpec]) State
supInit (strategy', specs') =
  -- TODO: should we return Ignore, as per OTP's supervisor, if no child starts?
  let initState = ( ( -- as a NominalDiffTime (in seconds)
                      restartPeriod ^= configuredRestartPeriod
                    )
                  . (strategy ^= strategy')
                  $ emptyState
                  )

  in (foldlM initChild initState specs' >>= return . (flip InitOk) Infinity)
       `catch` \(e :: SomeException) -> return $ InitStop (show e)
  where initChild :: State -> ChildSpec -> Process State
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

emptyState :: State
emptyState = State {
    _specs         = Seq.empty
  , _active        = Map.empty
  , _strategy      = restartAll
  , _restartPeriod = (fromIntegral (0 :: Integer)) :: NominalDiffTime
  , _restarts      = []
  , _stats         = emptyStats
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
                 -> AddChildReq
                 -> Process (ProcessReply AddChildResult State)
handleStartChild state req@(AddChild _ spec) =
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
-- TODO: stop all our children from left to right...
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
    strat        -> tryRestartBranch strat spec reason $ (active ^= active') state

tryRestartBranch :: RestartStrategy
                 -> ChildSpec
                 -> DiedReason
                 -> State
                 -> Process (ProcessAction State)
tryRestartBranch rs sp _ st = -- TODO: use DiedReason for logging...
  let mode' = mode rs
      tree' = case rs of
                RestartAll   _ _ -> childSpecs
                RestartLeft  _ _ -> subTreeL
                RestartRight _ _ -> subTreeR
                _                -> error "IllegalState"
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
    startIt s (_, cs) = ensureActive cs =<< doStartChild cs s

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
    childSpecs = st ^. specs

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
          return $ (bumpStats Active chType (+1)) $ markActive st' ref spec
        Left _ -> do -- TODO: handle this by policy
          -- All child failures are handled via monitor signals, apart from
          -- BadClosure, which comes back from doStartChild as (Left err).
          -- Since we cannot recover from that, there's no point in trying
          -- to start this child again (as the closure will never resolve),
          -- so we remove this child forthwith. We should provide a policy
          -- for handling this situation though...
          return $ ( (active ^: Map.filter (/= chKey))
                   . (bumpStats Active chType decrement)
                   . (bumpStats Specified chType decrement)
                   $ removeChild spec st
                   )
  where
    chKey         = childKey spec
    chType        = childType spec

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
tryStartChild spec =
  let proc = childRun spec in do
    mProc <- catch (unClosure proc >>= return . Right)
                   (\(e :: SomeException) -> return $ Left (show e))
    case mProc of
      Left err -> return $ Left (StartFailureBadClosure err)
      Right p  -> wrapClosure (childRegName spec) p >>= return . Right
  where wrapClosure :: Maybe RegisteredName
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
             (proc `catch` filterInitFailures supervisor self)
               `catchesExit` [
                   (\_ m -> handleMessageIf m (== ExitShutdown)
                                              (\_ -> return ()))
                 ]
           void $ monitor pid
           send pid ()
           return $ ChildRunning pid

        maybeRegister :: Maybe RegisteredName -> ProcessId -> Process ()
        maybeRegister Nothing              _   = return ()
        maybeRegister (Just (LocalName n)) pid = register n pid

        filterInitFailures :: ProcessId
                           -> ProcessId
                           -> ChildInitFailure
                           -> Process ()
        filterInitFailures sup pid ex = do
          case ex of
            ChildInitFailure _ -> liftIO $ throwIO ex
            ChildInitIgnore    -> MP.cast sup $ IgnoreChildReq pid

--------------------------------------------------------------------------------
-- Child Termination/Shutdown                                                 --
--------------------------------------------------------------------------------

terminateChildren :: State -> Process ()
terminateChildren state = do
  let children = toList $ state ^. specs
  pids <- forM children $ \ch -> do
    pid <- spawnLocal $ asyncTerminate ch $ (active ^= Map.empty) state
    void $ monitor pid
    return pid
  _ <- collectExits [] pids
  -- TODO: report errs???
  return ()
  where
    asyncTerminate :: Child -> State -> Process ()
    asyncTerminate (cr, cs) state' = void $ doTerminateChild cr cs state'

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
      state' <- shutdownComplete state stopped
      return $ ( (active ^: Map.delete pid)
               $ state'
               )
  where
    shutdownComplete :: State -> DiedReason -> Process State
    shutdownComplete state' DiedNormal        = return $ updateStopped
    shutdownComplete state' (r :: DiedReason) = do
      logShutdownError r >> return state'

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
-- Logging/Reporting                                                          --
--------------------------------------------------------------------------------

errorMaxIntensityReached :: ExitReason
errorMaxIntensityReached = ExitOther "ReachedMaxRestartIntensity"

logShutdown :: ChildKey -> Process ()
logShutdown _ = return ()

logShutdownError :: DiedReason -> Process ()
logShutdownError r = liftIO $ putStrLn $ "Child Termination Error: " ++ (show r)

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
    ChildRunning (pid :: ProcessId) ->
      active ^: Map.insert pid (childKey spec) $ state
    _ ->
      error $ "InternalError"

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

