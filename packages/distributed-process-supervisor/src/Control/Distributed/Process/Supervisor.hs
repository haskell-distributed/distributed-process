{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE PatternGuards             #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Supervisor
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
-- Unless otherwise stated, all client functions in this module will cause the
-- calling process to exit unless the specified supervisor process can be resolved.
--
-- [Supervision Principles]
--
-- A supervisor is responsible for starting, stopping and monitoring its child
-- processes so as to keep them alive by restarting them when necessary.
--
-- The supervisor's children are defined as a list of child specifications
-- (see "ChildSpec"). When a supervisor is started, its children are started
-- in left-to-right (insertion order) according to this list. When a supervisor
-- stops (or exits for any reason), it will stop all its children before exiting.
-- Child specs can be added to the supervisor after it has started, either on
-- the left or right of the existing list of child specs.
--
-- [Restart Strategies]
--
-- Supervisors are initialised with a 'RestartStrategy', which describes how
-- the supervisor should respond to a child that exits and should be restarted
-- (see below for the rules governing child restart eligibility). Each restart
-- strategy comprises a 'RestartMode' and 'RestartLimit', which govern how
-- the restart should be handled, and the point at which the supervisor
-- should give up and stop itself respectively.
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
-- stopping all its children (in left-to-right order) and exit with the
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
-- [Child Restart and Stop Policies]
--
-- When the supervisor detects that a child has died, the 'RestartPolicy'
-- configured in the child specification is used to determin what to do. If
-- the this is set to @Permanent@, then the child is always restarted.
-- If it is @Temporary@, then the child is never restarted and the child
-- specification is removed from the supervisor. A @Transient@ child will
-- be restarted only if it exits /abnormally/, otherwise it is left
-- inactive (but its specification is left in place). Finally, an @Intrinsic@
-- child is treated like a @Transient@ one, except that if /this/ kind of child
-- exits /normally/, then the supervisor will also exit normally.
--
-- When the supervisor does stop a child process, the "ChildStopPolicy"
-- provided with the 'ChildSpec' determines how the supervisor should go
-- about doing so. If this is "StopImmediately", then the child will
-- be killed without further notice, which means the child will /not/ have
-- an opportunity to clean up any internal state and/or release any held
-- resources. If the policy is @StopTimeout delay@ however, the child
-- will be sent an /exit signal/ instead, i.e., the supervisor will cause
-- the child to exit via @exit childPid ExitShutdown@, and then will wait
-- until the given @delay@ for the child to exit normally. If this does not
-- happen within the given delay, the supervisor will revert to the more
-- aggressive "StopImmediately" policy and try again. Any errors that
-- occur during a timed-out shutdown will be logged, however exit reasons
-- resulting from "StopImmediately" are ignored.
--
-- [Creating Child Specs]
--
-- The 'ToChildStart' typeclass simplifies the process of defining a 'ChildStart'
-- providing two default instances from which a 'ChildStart' datum can be
-- generated. The first, takes a @Closure (Process ())@, where the enclosed
-- action (in the @Process@ monad) is the actual (long running) code that we
-- wish to supervise. In the case of a /managed process/, this is usually the
-- server loop, constructed by evaluating some variant of @ManagedProcess.serve@.
--
-- The second instance supports returning a /handle/ which can contain extra
-- data about the child process - usually this is a newtype wrapper used by
-- clients to communicate with the process.
--
-- When the supervisor spawns its child processes, they should be linked to their
-- parent (i.e., the supervisor), such that even if the supervisor is killed
-- abruptly by an asynchronous exception, the children will still be taken down
-- with it, though somewhat less ceremoniously in that case. This behaviour is
-- injected by the supervisor for any "ChildStart" built on @Closure (Process ())@
-- automatically, but the /handle/ based approach requires that the @Closure@
-- responsible for spawning does the linking itself.
--
-- Finally, we provide a simple shortcut to @staticClosure@, for consumers
-- who've manually registered with the /remote table/ and don't with to use
-- tempate haskell (e.g. users of the Explicit closures API).
--
-- [Supervision Trees & Supervisor Shutdown]
--
-- To create a supervision tree, one simply adds supervisors below one another
-- as children, setting the @childType@ field of their 'ChildSpec' to
-- @Supervisor@ instead of @Worker@. Supervision tree can be arbitrarilly
-- deep, and it is for this reason that we recommend giving a @Supervisor@ child
-- an arbitrary length of time to stop, by setting the delay to @Infinity@
-- or a very large @TimeInterval@.
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Supervisor
  ( -- * Defining and Running a Supervisor
    ChildSpec(..)
  , ChildKey
  , ChildType(..)
  , ChildStopPolicy(..)
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
  , ChildPid
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
  , stopChild
  , StopChildResult(..)
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
  , getRestartIntensity
  , definedChildren
  , definedWorkers
  , definedSupervisors
  , runningChildren
  , runningWorkers
  , runningSupervisors
    -- * Additional (Misc) Types
  , StartFailure(..)
  , ChildInitFailure(..)
  ) where

import Control.DeepSeq (NFData)

import Control.Distributed.Process.Supervisor.Types
import Control.Distributed.Process
  ( Process
  , ProcessId
  , MonitorRef
  , DiedReason(..)
  , Match
  , Handler(..)
  , Message
  , ProcessMonitorNotification(..)
  , Closure
  , Static
  , exit
  , kill
  , match
  , matchIf
  , monitor
  , getSelfPid
  , liftIO
  , catchExit
  , catchesExit
  , catches
  , die
  , link
  , send
  , register
  , spawnLocal
  , unsafeWrapMessage
  , unmonitor
  , withMonitor_
  , expect
  , unClosure
  , receiveWait
  , receiveTimeout
  , handleMessageIf
  )
import Control.Distributed.Process.Management (mxNotify, MxEvent(MxUser))
import Control.Distributed.Process.Extras.Internal.Primitives hiding (monitor)
import Control.Distributed.Process.Extras.Internal.Types
  ( ExitReason(..)
  )
import Control.Distributed.Process.ManagedProcess
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
  , Priority()
  , DispatchPriority
  , UnhandledMessagePolicy(Drop)
  , ExitState
  , exitState
  )
import qualified Control.Distributed.Process.ManagedProcess.UnsafeClient as Unsafe
  ( call
  , cast
  )
import qualified Control.Distributed.Process.ManagedProcess as MP
  ( pserve
  )
import Control.Distributed.Process.ManagedProcess.Server.Priority
  ( prioritiseCast_
  , prioritiseCall_
  , prioritiseInfo_
  , setPriority
  , evalAfter
  )
import Control.Distributed.Process.ManagedProcess.Server.Restricted
  ( RestrictedProcess
  , Result
  , RestrictedAction
  , getState
  , putState
  )
import qualified Control.Distributed.Process.ManagedProcess.Server.Restricted as Restricted
  ( handleCallIf
  , handleCall
  , handleCast
  , reply
  , continue
  )
import Control.Distributed.Process.Extras.SystemLog
  ( LogClient
  , LogChan
  , LogText
  , Logger(..)
  )
import qualified Control.Distributed.Process.Extras.SystemLog as Log
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Static
  ( staticClosure
  )
import Control.Exception (SomeException, throwIO)
import Control.Monad.Catch (catch, finally, mask)
import Control.Monad (void, forM)

import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (.>)
  , (^=)
  , (^.)
  )
import Data.Binary (Binary)
import Data.Foldable (find, foldlM, toList)
import Data.List (foldl')
import qualified Data.List as List (lookup)
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

-- TODO: ToChildStart belongs with rest of types in
-- Control.Distributed.Process.Supervisor.Types

-- | A type that can be converted to a 'ChildStart'.
class ToChildStart a where
  toChildStart :: a -> Process ChildStart

instance ToChildStart (Closure (Process ())) where
  toChildStart = return . RunClosure

instance ToChildStart (Closure (SupervisorPid -> Process (ChildPid, Message))) where
  toChildStart = return . CreateHandle

instance ToChildStart (Static (Process ())) where
  toChildStart = toChildStart . staticClosure

-- internal APIs. The corresponding XxxResult types are in
-- Control.Distributed.Process.Supervisor.Types

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

data StartChildReq = StartChild !ChildKey
  deriving (Typeable, Generic)
instance Binary StartChildReq where
instance NFData StartChildReq where

data RestartChildReq = RestartChildReq !ChildKey
  deriving (Typeable, Generic, Show, Eq)
instance Binary RestartChildReq where
instance NFData RestartChildReq where

data DelayedRestart = DelayedRestart !ChildKey !DiedReason
  deriving (Typeable, Generic, Show, Eq)
instance Binary DelayedRestart where
instance NFData DelayedRestart

data StopChildReq = StopChildReq !ChildKey
  deriving (Typeable, Generic, Show, Eq)
instance Binary StopChildReq where
instance NFData StopChildReq where

data IgnoreChildReq = IgnoreChildReq !ChildPid
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
  , _active          :: Map ChildPid ChildKey
  , _strategy        :: RestartStrategy
  , _restartPeriod   :: NominalDiffTime
  , _restarts        :: [UTCTime]
  , _stats           :: SupervisorStats
  , _logger          :: LogSink
  , shutdownStrategy :: ShutdownMode
  }

supErrId :: String -> String
supErrId s = "Control.Distributed.Process" ++ s

--------------------------------------------------------------------------------
-- Starting/Running Supervisor                                                --
--------------------------------------------------------------------------------

-- | Start a supervisor (process), running the supplied children and restart
-- strategy.
--
-- > start = spawnLocal . run
--
start :: RestartStrategy -> ShutdownMode -> [ChildSpec] -> Process SupervisorPid
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
-- 'stopChild').
--
deleteChild :: Addressable a => a -> ChildKey -> Process DeleteChildResult
deleteChild sid childKey = Unsafe.call sid $ DeleteChild childKey

-- | Stop a running child.
--
stopChild :: Addressable a
               => a
               -> ChildKey
               -> Process StopChildResult
stopChild sid = Unsafe.call sid . StopChildReq

-- | Forcibly restart a running child.
--
restartChild :: Addressable a
             => a
             -> ChildKey
             -> Process RestartChildResult
restartChild sid = Unsafe.call sid . RestartChildReq

-- | Gracefully stop/shutdown a running supervisor. Returns immediately if the
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
    Just p  -> withMonitor_ p $ do
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
  catch (foldlM initChild initState specs' >>= return . (flip InitOk) Infinity)
        (\(e :: SomeException) -> do
          sup <- getSelfPid
          logEntry Log.error $
            mkReport "Could not init supervisor " sup "noproc" (show e)
          return $ InitStop (show e))
  where
    initChild :: State -> ChildSpec -> Process State
    initChild st ch =
      case (findChild (childKey ch) st) of
        Just (ref, _) -> die $ StartFailureDuplicateChild ref
        Nothing       -> tryStartChild ch >>= initialised st ch

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
    Nothing  -> die $ (supErrId ".initChild:child=") ++ (childKey spec) ++ ":InvalidChildRef"
    Just childPid -> do
      return $ ( (active ^: Map.insert childPid chId)
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
      , prioritiseInfo_ (\(DelayedRestart _ _)               -> setPriority 80 )
      , prioritiseCall_ (\(_ :: FindReq) ->
                          (setPriority 10) :: Priority (Maybe (ChildRef, ChildSpec)))
      ]

processDefinition :: ProcessDefinition State
processDefinition =
  defaultProcess {
    apiHandlers = [
       Restricted.handleCast   handleIgnore
       -- adding, removing and (optionally) starting new child specs
     , handleCall              handleStopChild
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
  , infoHandlers = [ handleInfo handleMonitorSignal
                   , handleInfo handleDelayedRestart
                   ]
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
handleIgnore (IgnoreChildReq childPid) = do
  {- not only must we take this child out of the `active' field,
     we also delete the child spec if it's restart type is Temporary,
     since restarting Temporary children is dis-allowed -}
  state <- getState
  let (cId, active') =
        Map.updateLookupWithKey (\_ _ -> Nothing) childPid $ state ^. active
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

handleDelayedRestart :: State
                     -> DelayedRestart
                     -> Process (ProcessAction State)
handleDelayedRestart state (DelayedRestart key reason) =
  let child = findChild key state in do
  case child of
    Nothing ->
      continue state -- a child could've been stopped and removed by now
    Just ((ChildRestarting childPid), spec) -> do
      -- TODO: we ignore the unnecessary .active re-assignments in
      -- tryRestartChild, in order to keep the code simple - it would be good to
      -- clean this up so we don't have to though...
      tryRestartChild childPid state (state ^. active) spec reason
    Just other -> do
      die $ ExitOther $ (supErrId ".handleDelayedRestart:InvalidState: ") ++ (show other)

handleStopChild :: State
                     -> StopChildReq
                     -> Process (ProcessReply StopChildResult State)
handleStopChild state (StopChildReq key) =
  let child = findChild key state in
  case child of
    Nothing ->
      reply StopChildUnknownId state
    Just (ChildStopped, _) ->
      reply StopChildOk state
    Just (ref, spec) ->
      reply StopChildOk =<< doStopChild ref spec state

handleGetStats :: StatsReq
               -> RestrictedProcess State (Result SupervisorStats)
handleGetStats _ = Restricted.reply . (^. stats) =<< getState

--------------------------------------------------------------------------------
-- Child Monitoring                                                           --
--------------------------------------------------------------------------------

handleMonitorSignal :: State
                    -> ProcessMonitorNotification
                    -> Process (ProcessAction State)
handleMonitorSignal state (ProcessMonitorNotification _ childPid reason) = do
  let (cId, active') =
        Map.updateLookupWithKey (\_ _ -> Nothing) childPid $ state ^. active
  let mSpec =
        case cId of
          Nothing -> Nothing
          Just c  -> fmap snd $ findChild c state
  case mSpec of
    Nothing   -> continue $ (active ^= active') state
    Just spec -> tryRestart childPid state active' spec reason

--------------------------------------------------------------------------------
-- Child Monitoring                                                           --
--------------------------------------------------------------------------------

handleShutdown :: ExitState State -> ExitReason -> Process ()
handleShutdown state r@(ExitOther reason) = stopChildren (exitState state) r >> die reason
handleShutdown state r                    = stopChildren (exitState state) r

--------------------------------------------------------------------------------
-- Child Start/Restart Handling                                               --
--------------------------------------------------------------------------------

tryRestart :: ChildPid
           -> State
           -> Map ChildPid ChildKey
           -> ChildSpec
           -> DiedReason
           -> Process (ProcessAction State)
tryRestart childPid state active' spec reason = do
  sup <- getSelfPid
  logEntry Log.debug $ do
    mkReport "signalled restart" sup (childKey spec) (show reason)
  case state ^. strategy of
    RestartOne _ -> tryRestartChild childPid state active' spec reason
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
                RestartEach     _ -> stopStart (order mode')
                _                 -> restartBranch mode'
    in do us <- getSelfPid
          a <- proc tree'
          report $ SupervisorBranchRestarted us (childKey sp) dr rs
          return a
  where
    stopStart :: RestartOrder -> ChildSpecs -> Process (ProcessAction State)
    stopStart order' tree = do
      let tree' = case order' of
                    LeftToRight -> tree
                    RightToLeft -> Seq.reverse tree
      state <- addRestart activeState
      case state of
        Nothing  -> do us <- getSelfPid
                       let reason = errorMaxIntensityReached
                       report $ SupervisorShutdown us (shutdownStrategy st) reason
                       die reason
        Just st' -> apply (foldlM stopStartIt st' tree')

    restartBranch :: RestartMode -> ChildSpecs -> Process (ProcessAction State)
    restartBranch mode' tree = do
      state <- addRestart activeState
      case state of
        Nothing  -> die errorMaxIntensityReached
        Just st' -> do
          let (stopTree, startTree) = mkTrees mode' tree
          foldlM stopIt st' stopTree >>= \s -> apply $ foldlM startIt s startTree

    mkTrees :: RestartMode -> ChildSpecs -> (ChildSpecs, ChildSpecs)
    mkTrees (RestartInOrder LeftToRight)  t = (t, t)
    mkTrees (RestartInOrder RightToLeft)  t = let rev = Seq.reverse t in (rev, rev)
    mkTrees (RestartRevOrder LeftToRight) t = (t, Seq.reverse t)
    mkTrees (RestartRevOrder RightToLeft) t = (Seq.reverse t, t)
    mkTrees _                             _    = error "mkTrees.INVALID_STATE"

    stopStartIt :: State -> Child -> Process State
    stopStartIt s ch@(cr, cs) = do
      us <- getSelfPid
      cPid <- resolve cr
      report $ SupervisedChildRestarting us cPid (childKey cs) (ExitOther "RestartedBySupervisor")
      doStopChild cr cs s >>= (flip startIt) ch

    stopIt :: State -> Child -> Process State
    stopIt s (cr, cs) = do
      us <- getSelfPid
      cPid <- resolve cr
      report $ SupervisedChildRestarting us cPid (childKey cs) (ExitOther "RestartedBySupervisor")
      doStopChild cr cs s

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
      | (Left err) <- it = die $ ExitOther $ branchErrId ++ (childKey cs) ++ ": " ++ (show err)
      | otherwise = error "IllegalState"

    branchErrId :: String
    branchErrId = supErrId ".tryRestartBranch:child="

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

      -- TODO: THIS IS INCORRECT... currently (below), we stop
      -- the branch in parallel, but wait on all the exits and then
      -- restart sequentially (based on 'order'). That's not what the
      -- 'RestartParallel' mode advertised, but more importantly, it's
      -- not clear what the semantics for error handling (viz restart errors)
      -- should actually be.

      asyncs <- forM (toList tree') $ \ch -> async $ asyncStop ch
      (_errs, st') <- foldlM collectExits ([], activeState) asyncs
      -- TODO: report errs
      apply $ foldlM startIt st' tree'
      where
        asyncStop :: Child -> Process (Maybe (ChildKey, ChildPid))
        asyncStop (cr, cs) = do
          mPid <- resolve cr
          case mPid of
            Nothing  -> return Nothing
            Just childPid -> do
              void $ doStopChild cr cs activeState
              return $ Just (childKey cs, childPid)

        collectExits :: ([ExitReason], State)
                     -> Async (Maybe (ChildKey, ChildPid))
                     -> Process ([ExitReason], State)
        collectExits (errs, state) hAsync = do
          -- we perform a blocking wait on each handle, since we'll
          -- always wait until the last shutdown has occurred anyway
          asyncResult <- wait hAsync
          let res = mergeState asyncResult state
          case res of
            Left err -> return ((err:errs), state)
            Right st -> return (errs, st)

        mergeState :: AsyncResult (Maybe (ChildKey, ChildPid))
                   -> State
                   -> Either ExitReason State
        mergeState (AsyncDone Nothing)           state = Right state
        mergeState (AsyncDone (Just (key, childPid))) state = Right $ mergeIt key childPid state
        mergeState (AsyncFailed r)               _     = Left $ ExitOther (show r)
        mergeState (AsyncLinkFailed r)           _     = Left $ ExitOther (show r)
        mergeState _                             _     = Left $ ExitOther "IllegalState"

        mergeIt :: ChildKey -> ChildPid -> State -> State
        mergeIt key childPid state =
          -- TODO: lookup the old ref -> childPid and delete from the active map
          ( (active ^: Map.delete childPid)
          $ maybe state id (updateChild key (setChildStopped False) state)
          )
    -}

tryRestartChild :: ChildPid
                -> State
                -> Map ChildPid ChildKey
                -> ChildSpec
                -> DiedReason
                -> Process (ProcessAction State)
tryRestartChild childPid st active' spec reason
  | DiedNormal <- reason
  , True       <- isTransient (childRestart spec) = continue childDown
  | True       <- isTemporary (childRestart spec) = continue childRemoved
  | DiedNormal <- reason
  , True       <- isIntrinsic (childRestart spec) = stopWith updateStopped ExitNormal
  | otherwise     = doRestartChild childPid spec reason st
  where
    childDown     = (active ^= active') $ updateStopped
    childRemoved  = (active ^= active') $ removeChild spec st
    updateStopped = maybe st id $ updateChild chKey (setChildStopped False) st
    chKey         = childKey spec

doRestartChild :: ChildPid -> ChildSpec -> DiedReason -> State -> Process (ProcessAction State)
doRestartChild pid spec reason state = do -- TODO: use ChildPid and DiedReason to log
  state' <- addRestart state
  case state' of
    Nothing -> -- die errorMaxIntensityReached
      case (childRestartDelay spec) of
        Nothing  -> die errorMaxIntensityReached
        Just del -> doRestartDelay pid del spec reason state
    Just st -> do
      sup <- getSelfPid
      report $ SupervisedChildRestarting sup (Just pid) (childKey spec) (ExitOther $ show reason)
      start' <- doStartChild spec st
      case start' of
        Right (ref, st') -> continue $ markActive st' ref spec
        Left err -> do
          -- All child failures are handled via monitor signals, apart from
          -- BadClosure and UnresolvableAddress from the StarterProcess
          -- variants of ChildStart, which both come back from
          -- doStartChild as (Left err).
          if isTemporary (childRestart spec)
             then do
               logEntry Log.warning $
                 mkReport "Error in temporary child" sup (childKey spec) (show err)
               continue $ ( (active ^: Map.filter (/= chKey))
                   . (bumpStats Active chType decrement)
                   . (bumpStats Specified chType decrement)
                   $ removeChild spec st)
             else do
               logEntry Log.error $
                 mkReport "Unrecoverable error in child. Stopping supervisor"
                 sup (childKey spec) (show err)
               stopWith st $ ExitOther $ "Unrecoverable error in child " ++ (childKey spec)
  where
    chKey  = childKey spec
    chType = childType spec


doRestartDelay :: ChildPid
               -> TimeInterval
               -> ChildSpec
               -> DiedReason
               -> State
               -> Process (ProcessAction State)
doRestartDelay oldPid rDelay spec reason state = do
  evalAfter rDelay
            (DelayedRestart (childKey spec) reason)
          $ ( (active ^: Map.filter (/= chKey))
            . (bumpStats Active chType decrement)
            -- . (restarts ^= [])
            $ maybe state id (updateChild chKey (setChildRestarting oldPid) state)
            )
  where
    chKey  = childKey spec
    chType = childType spec

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
        Nothing -> die $ (supErrId ".doStartChild.InternalError:") ++ show spec
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
          Right p  -> wrapClosure childKey childRegName p >>= return . Right
      CreateHandle fn -> do
        mFn <- catch (unClosure fn >>= return . Right)
                     (\(e :: SomeException) -> return $ Left (show e))
        case mFn of
          Left err  -> logStartFailure $ StartFailureBadClosure err
          Right fn' -> do
            wrapHandle childKey childRegName fn' >>= return . Right
  where
    logStartFailure sf = do
      sup <- getSelfPid
      -- logEntry Log.error $ mkReport "Child Start Error" sup childKey (show sf)
      report $ SupervisedChildStartFailure sup sf childKey
      return $ Left sf

    wrapClosure :: ChildKey
                -> Maybe RegisteredName
                -> Process ()
                -> Process ChildRef
    wrapClosure key regName proc = do
      supervisor <- getSelfPid
      childPid <- spawnLocal $ do
        self <- getSelfPid
        link supervisor -- die if our parent dies
        maybeRegister regName self
        () <- expect    -- wait for a start signal (pid is still private)
        -- we translate `ExitShutdown' into a /normal/ exit
        (proc
          `catchesExit` [
              (\_ m -> handleMessageIf m (\r -> r == ExitShutdown)
                                         (\_ -> return ()))
            , (\_ m -> handleMessageIf m (\(ExitOther _) -> True)
                                         (\r -> logExit supervisor self r))
            ])
           `catches` [ Handler $ filterInitFailures supervisor self
                     , Handler $ logFailure supervisor self ]
      void $ monitor childPid
      send childPid ()
      let cRef = ChildRunning childPid
      report $ SupervisedChildStarted supervisor cRef key
      return cRef

    wrapHandle :: ChildKey
               -> Maybe RegisteredName
               -> (SupervisorPid -> Process (ChildPid, Message))
               -> Process ChildRef
    wrapHandle key regName proc = do
      super <- getSelfPid
      (childPid, msg) <- proc super
      void $ monitor childPid
      maybeRegister regName childPid
      let cRef = ChildRunningExtra childPid msg
      report $ SupervisedChildStarted super cRef key
      return cRef

    maybeRegister :: Maybe RegisteredName -> ChildPid -> Process ()
    maybeRegister Nothing                         _     = return ()
    maybeRegister (Just (LocalName n))            pid   = register n pid
    maybeRegister (Just (CustomRegister clj))     pid   = do
        -- TODO: cache your closures!!!
        mProc <- catch (unClosure clj >>= return . Right)
                       (\(e :: SomeException) -> return $ Left (show e))
        case mProc of
          Left err -> die $ ExitOther (show err)
          Right p  -> p pid

filterInitFailures :: SupervisorPid
                   -> ChildPid
                   -> ChildInitFailure
                   -> Process ()
filterInitFailures sup childPid ex = do
  case ex of
    ChildInitFailure _ -> do
      -- This is used as a `catches` handler in multiple places
      -- and matches first before the other handlers that
      -- would call logFailure.
      -- We log here to avoid silent failure in those cases.
      -- logEntry Log.error $ mkReport "ChildInitFailure" sup (show childPid) (show ex)
      report $ SupervisedChildInitFailed sup childPid ex
      liftIO $ throwIO ex
    ChildInitIgnore    -> Unsafe.cast sup $ IgnoreChildReq childPid

--------------------------------------------------------------------------------
-- Child Stop/Shutdown                                                 --
--------------------------------------------------------------------------------

stopChildren :: State -> ExitReason -> Process ()
stopChildren state er = do
  us <- getSelfPid
  let strat = shutdownStrategy state
  report $ SupervisorShutdown us strat er
  case strat of
    ParallelShutdown -> do
      let allChildren = toList $ state ^. specs
      terminatorPids <- forM allChildren $ \ch -> do
        pid <- spawnLocal $ void $ syncStop ch $ (active ^= Map.empty) state
        mRef <- monitor pid
        return (mRef, pid)
      terminationErrors <- collectExits [] $ zip terminatorPids (map snd allChildren)
      -- it seems these would also be logged individually in doStopChild
      case terminationErrors of
        [] -> return ()
        _ -> do
          sup <- getSelfPid
          void $ logEntry Log.error $
            mkReport "Errors in stopChildren / ParallelShutdown"
            sup "n/a" (show terminationErrors)
    SequentialShutdown ord -> do
      let specs'      = state ^. specs
      let allChildren = case ord of
                          RightToLeft -> Seq.reverse specs'
                          LeftToRight -> specs'
      void $ foldlM (flip syncStop) state (toList allChildren)
  where
    syncStop :: Child -> State -> Process State
    syncStop (cr, cs) state' = doStopChild cr cs state'

    collectExits :: [(ProcessId, DiedReason)]
                 -> [((MonitorRef, ProcessId), ChildSpec)]
                 -> Process [(ProcessId, DiedReason)]
    collectExits errors []   = return errors
    collectExits errors pids = do
      (ref, pid, reason) <- receiveWait [
          match (\(ProcessMonitorNotification ref' pid' reason') -> do
                    return (ref', pid', reason'))
        ]
      let remaining = [p | p <- pids, (snd $ fst p) /= pid]
      let spec = List.lookup (ref, pid) pids
      case (reason, spec) of
        (DiedUnknownId, _) -> collectExits errors remaining
        (DiedNormal, _) -> collectExits errors remaining
        (_, Nothing) -> collectExits errors remaining
        (DiedException _, Just sp') -> do
            if (childStop sp') == StopImmediately
              then collectExits errors remaining
              else collectExits ((pid, reason):errors) remaining
        _ -> collectExits ((pid, reason):errors) remaining

doStopChild :: ChildRef -> ChildSpec -> State -> Process State
doStopChild ref spec state = do
  us <- getSelfPid
  mPid <- resolve ref
  case mPid of
    Nothing  -> return state -- an already dead child is not an error
    Just pid -> do
      stopped <- childShutdown (childStop spec) pid state
      report $ SupervisedChildStopped us ref stopped
      -- state' <- shutdownComplete state pid stopped
      return $ ( (active ^: Map.delete pid)
               $ updateStopped
               )
  where
    {-shutdownComplete :: State -> ChildPid -> DiedReason -> Process State-}
    {-shutdownComplete _      _   DiedNormal        = return $ updateStopped-}
    {-shutdownComplete state' pid (r :: DiedReason) = do-}
      {-logShutdown (state' ^. logger) chKey pid r >> return state'-}

    chKey         = childKey spec
    updateStopped = maybe state id $ updateChild chKey (setChildStopped False) state

childShutdown :: ChildStopPolicy
              -> ChildPid
              -> State
              -> Process DiedReason
childShutdown policy childPid st = mask $ \restore -> do
  case policy of
    (StopTimeout t) -> exit childPid ExitShutdown >> await restore childPid t st
    -- we ignore DiedReason for brutal kills
    StopImmediately -> do
      kill childPid "StoppedBySupervisor"
      void $ await restore childPid Infinity st
      return DiedNormal
  where
    await restore' childPid' delay state = do
      -- We require and additional monitor here when child shutdown occurs
      -- during a restart which was triggered by the /old/ monitor signal.
      -- Just to be safe, we monitor the child immediately to be sure it goes.
      mRef <- monitor childPid'
      let recv = case delay of
                   Infinity -> receiveWait (matches mRef) >>= return . Just
                   NoDelay  -> receiveTimeout 0 (matches mRef)
                   Delay t  -> receiveTimeout (asTimeout t) (matches mRef)
      -- let recv' =  if monitored then recv else withMonitor childPid' recv
      res <- recv `finally` (unmonitor mRef)
      restore' $ maybe (childShutdown StopImmediately childPid' state) return res

    matches :: MonitorRef -> [Match DiedReason]
    matches m = [
          matchIf (\(ProcessMonitorNotification m' _ _) -> m == m')
                  (\(ProcessMonitorNotification _ _ r) -> return r)
        ]

--------------------------------------------------------------------------------
-- Loging/Reporting                                                          --
--------------------------------------------------------------------------------

errorMaxIntensityReached :: ExitReason
errorMaxIntensityReached = ExitOther "ReachedMaxRestartIntensity"

report :: MxSupervisor -> Process ()
report = mxNotify . MxUser . unsafeWrapMessage

{-logShutdown :: LogSink -> ChildKey -> ChildPid -> DiedReason -> Process ()-}
{-logShutdown log' child childPid reason = do-}
    {-sup <- getSelfPid-}
    {-Log.info log' $ mkReport banner sup (show childPid) shutdownReason-}
  {-where-}
    {-banner         = "Child Shutdown Complete"-}
    {-shutdownReason = (show reason) ++ ", child-key: " ++ child-}

logExit :: SupervisorPid -> ChildPid -> ExitReason -> Process ()
logExit sup pid er = do
  report $ SupervisedChildDied sup pid er

logFailure :: SupervisorPid -> ChildPid -> SomeException -> Process ()
logFailure sup childPid ex = do
  logEntry Log.notice $ mkReport "Detected Child Exit" sup (show childPid) (show ex)
  liftIO $ throwIO ex

logEntry :: (LogChan -> LogText -> Process ()) -> String -> Process ()
logEntry lg = Log.report lg Log.logChannel

mkReport :: String -> SupervisorPid -> String -> String -> String
mkReport b s c r = foldl' (\x xs -> xs ++ " " ++ x) "" (reverse items)
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

setChildRestarting :: ChildPid -> Child -> Prefix -> Suffix -> State -> Maybe State
setChildRestarting oldPid child prefix remaining st =
  let spec   = snd child
      newRef = ChildRestarting oldPid
  in Just $ (specs ^= prefix >< ((newRef, spec) <| remaining)) st

-- setChildStarted :: ChildPid ->

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
    ChildRunning (pid :: ChildPid)  -> inserted pid
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

active :: Accessor State (Map ChildPid ChildKey)
active = accessor _active (\act' st -> st { _active = act' })

strategy :: Accessor State RestartStrategy
strategy = accessor _strategy (\s st -> st { _strategy = s })

restartIntensity :: Accessor RestartStrategy RestartLimit
restartIntensity = accessor intensity (\i l -> l { intensity = i })

-- | The "RestartLimit" for a given "RestartStrategy"
getRestartIntensity :: RestartStrategy -> RestartLimit
getRestartIntensity = (^. restartIntensity)

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

-- | How many child specs are defined for this supervisor
definedChildren :: SupervisorStats -> Int
definedChildren = (^. children)

workers :: Accessor SupervisorStats Int
workers = accessor _workers (\c st -> st { _workers = c })

-- | How many child specs define a worker (non-supervisor)
definedWorkers :: SupervisorStats -> Int
definedWorkers = (^. workers)

supervisors :: Accessor SupervisorStats Int
supervisors = accessor _supervisors (\c st -> st { _supervisors = c })

-- | How many child specs define a supervisor?
definedSupervisors :: SupervisorStats -> Int
definedSupervisors = (^. supervisors)

running :: Accessor SupervisorStats Int
running = accessor _running (\r st -> st { _running = r })

-- | How many running child processes.
runningChildren :: SupervisorStats -> Int
runningChildren = (^. running)

activeWorkers :: Accessor SupervisorStats Int
activeWorkers = accessor _activeWorkers (\c st -> st { _activeWorkers = c })

-- | How many worker (non-supervisor) child processes are running.
runningWorkers :: SupervisorStats -> Int
runningWorkers = (^. activeWorkers)

activeSupervisors :: Accessor SupervisorStats Int
activeSupervisors = accessor _activeSupervisors (\c st -> st { _activeSupervisors = c })

-- | How many supervisor child processes are running
runningSupervisors :: SupervisorStats -> Int
runningSupervisors = (^. activeSupervisors)
