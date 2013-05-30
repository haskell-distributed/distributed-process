{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE PatternGuards              #-}

module Control.Distributed.Process.Platform.Supervisor
  ( ChildKey
  , ChildType(..)
  , ChildSpec(..)
  , MaxRestarts
  , maxRestarts
  , RestartLimit(..)
  , limit
  , defaultLimits
  , RestartStrategy(..)
  , restartOne
  , restartAll
  , restartLeft
  , restartRight
  , ChildRef(..)
  , RestartPolicy(..)
  , ChildRestart(..)
  , SupervisorStats(..)
  , StaticLabel
  , AddChildResult(..)
  , RestartChildResult(..)
  , StartFailure(..)
  , DeleteChildResult(..)
  , Child
  , ChildInitFailure(..)
  , running
  , restarting
  , start
  , statistics
  , addChild
  , startChild
  , deleteChild
  , restartChild
  , lookupChild
  , listChildren
  ) where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.Internal.Primitives
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
  , modifyState
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( handleCallIf
  , handleCall
  , handleCast
  , reply
  , continue
  , say
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
import Data.Map (Map)
import qualified Data.Map as Map -- TODO: use Data.Map.Strict
import Data.Sequence (Seq, ViewL(EmptyL, (:<)), (<|), (><), filter)
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
defaultLimits = RestartLimit (MaxR 0) (seconds 1)

data RestartMode =
    LeftToRightStopStart
    {- ^ from left to right (insertion order), restart each child sequentially -}
  | LeftToRightRestart
    {- ^ from left to right (insertion order), stop each child,
     then restart then in the same (left to right) order -}
  | LeftToRightRestartReversed
    {- ^ from left to right (insertion order), stop each child,
     then restart then in the opposite (right to left) order -}
  | RightToLeftStopStart
    {- ^ from right to left (of insertion order), restart each child sequentially -}
  | RightToLeftRestart
    {- ^ from right to left (of insertion order), stop each child,
     then restart then in the same (right to left) order -}
  | RightToLeftRestartReversed
    {- ^ from right to left (of insertion order), stop each child,
     then restart then in the opposite (left to right) order -}
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
    , order     :: !RestartMode
    } -- ^ also restart all siblings
  | RestartLeft
    { intensity :: !RestartLimit
    , order     :: !RestartMode
    } -- ^ restart prior siblings (i.e., prior /start order/)
  | RestartRight
    { intensity :: !RestartLimit
    , order     :: !RestartMode
    } -- ^ restart subsequent siblings (i.e., subsequent /start order/)
  deriving (Typeable, Generic, Show)
instance Binary RestartStrategy where

restartOne :: RestartStrategy
restartOne = RestartOne defaultLimits

restartAll :: RestartStrategy
restartAll = RestartAll defaultLimits LeftToRightRestart

restartLeft :: RestartStrategy
restartLeft = RestartLeft defaultLimits LeftToRightRestart

restartRight :: RestartStrategy
restartRight = RestartRight defaultLimits LeftToRightRestart

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

running :: ChildRef -> Bool
running (ChildRunning _) = True
running _                = False

restarting :: ChildRef -> Bool
restarting (ChildRestarting _) = True
restarting _                   = False

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

-- | Specifies restart handling for a child spec.
--
-- When @DelayedRestart@ is given, the delay indicates what should happen
-- if a child, exceeds the supervisor's configured maximum restart intensity.
-- Such children are restarted as normal, unless they exit sufficiently
-- quickly and often to exceed the boundaries of the supervisors restart
-- strategy; then rather than stopping the supervisor, the supervisor will
-- continue attempting to start the child after waiting for at least the
-- specified delay.
--
data ChildRestart =
    Restart RestartPolicy               -- ^ restart according to the given policy
  | DelayedRestart RestartPolicy Delay  -- ^ perform a /delayed restart/
  deriving (Typeable, Generic, Eq, Show)
instance Binary ChildRestart where

-- | Specification for a child process. The child must be uniquely identified
-- by it's @childKey@ within the supervisor. The supervisor will start the child
-- itself, therefore @childRun@ should contain the child process' implementation
-- e.g., if the child is a long running server, this would be the server /loop/,
-- as with e.g., @ManagedProces.start@.
data ChildSpec = ChildSpec {
    childKey     :: !ChildKey
  , childType    :: !ChildType
  , childRestart :: !ChildRestart
  , childRun     :: !(Closure (Process ()))
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

data RestartChildResult =
    ChildRestartOk     !ChildRef
  | ChildRestartUnknownId
  | ChildRestartFailed !StartFailure
  deriving (Typeable, Generic, Show, Eq)
instance Binary RestartChildResult where

data IgnoreChildReq = IgnoreChildReq !ProcessId
  deriving (Typeable, Generic)
instance Binary IgnoreChildReq where

data TryAgainChildReq = TryAgainChildReq
  deriving (Typeable, Generic)
instance Binary TryAgainChildReq where

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

start :: RestartStrategy -> [ChildSpec] -> Process ProcessId
start s cs = spawnLocal $ run s cs

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

{-
terminateChild :: Addressable a
               => a
               -> ChildKey
               -> Process TerminateChildResult
terminateChild = undefined
-}

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
initialised _     _    (Left  err) = die $ ": " ++ (show err)
initialised state spec (Right ref) = do
  mPid <- resolve ref
  case mPid of
    Nothing  -> die $ (childKey spec) ++ ": InvalidChildRef"
    Just pid -> do
      return $ ( (active ^: Map.insert pid chId)
               . (specs  ^: ((ref, spec) <|))
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
  -- TODO: usage/restart/freq stats

serverDefinition :: PrioritisedProcessDefinition State
serverDefinition = prioritised processDefinition supPriorities
  where
    supPriorities :: [DispatchPriority State]
    supPriorities = [
        prioritiseCast_ (\(IgnoreChildReq _)                 -> setPriority 100)
      , prioritiseInfo_ (\(ProcessMonitorNotification _ _ _) -> setPriority 99 )
      , prioritiseCast_ (\(_ :: TryAgainChildReq)            -> setPriority 80 )
      , prioritiseCall_ (\(_ :: FindReq) ->
                          (setPriority 10) :: Priority (Maybe (ChildRef, ChildSpec)))
      ]

processDefinition :: ProcessDefinition State
processDefinition =
  defaultProcess {
    apiHandlers = [
       Restricted.handleCast   handleIgnoreChildReq
       -- adding, removing and (optionally) starting new child specs
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

handleIgnoreChildReq :: IgnoreChildReq
                     -> RestrictedProcess State RestrictedAction
handleIgnoreChildReq (IgnoreChildReq pid) = do
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
                 . (bump decrement)
                 . (resetChildIgnored c)
                 $ state
                 )
      Restricted.continue
  where
    resetChildIgnored :: ChildKey -> State -> State
    resetChildIgnored key state =
      maybe state id $ updateChild key setChildStopped state

setChildStopped :: Child -> Prefix -> Suffix -> State -> Maybe State
setChildStopped child prefix remaining state =
  let spec  = snd child
      rType = childRestart spec
  in case isTemporary rType of
    True  -> Just $ (specs ^= prefix >< remaining) $ state
    False -> Just $ (specs ^= prefix >< ((ChildStopped, spec) <| remaining)) state

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
--          Restricted.say $ "child " ++ (show ref) ++ " has stopped"
--          Restricted.say $ "active == " ++ (show $ st ^. active)
          putState $ ( (specs ^= pfx >< sfx)
                     . (bump decrement)
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
          let st' = ( (specs ^: ((ref, spec) <|))
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
      -- THIS DUPLICATES PART OF doRestartChild!!!
      started <- doStartChild spec state
      case started of
        Left err         -> reply (ChildRestartFailed err) state
        Right (ref, st') -> reply (ChildRestartOk ref) st'

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
      mSpec =
        case cId of
          Nothing -> Nothing
          Just c  -> fmap snd $ findChild c state
  --  liftIO $ putStrLn $ "restart " ++ (show mSpec)
  -- change the state
  -- bump stats
  case mSpec of
    Nothing   -> continue $ (active ^= active') state
    Just spec -> tryRestartChild state active' spec reason

--------------------------------------------------------------------------------
-- Child Monitoring                                                           --
--------------------------------------------------------------------------------

handleShutdown :: State -> ExitReason -> Process ()
handleShutdown _ (ExitOther reason) = {- (liftIO $ putStrLn reason) >> -} die reason
handleShutdown _ _                  = return ()

--------------------------------------------------------------------------------
-- Child Start/Restart Handling                                               --
--------------------------------------------------------------------------------

tryRestart :: State
           -> Map ProcessId ChildKey
           -> ChildSpec
           -> DiedReason
           -> Process (ProcessAction State)
tryRestart state active' spec reason = do
  case state ^. strategy of
    RestartOne _ -> tryRestartChild state active' spec reason

tryRestartChild :: State
                -> Map ProcessId ChildKey
                -> ChildSpec
                -> DiedReason
                -> Process (ProcessAction State)
tryRestartChild st active' spec reason
  | DiedNormal <- reason
  , True       <- isTransient (childRestart spec) = continue $ down $ updateStopped
  | True       <- isTemporary (childRestart spec) = continue $ down $ removeChild spec st
  | DiedNormal <- reason
  , True       <- isIntrinsic (childRestart spec) = stop $ ExitNormal  -- TODO: STOP OUR CHILDREN
  | otherwise                                     = continue =<< doRestartChild spec st
  where
    chKey         = childKey spec
    down st'      = (active ^= active') $ st'
    updateStopped = maybe st id $ updateChild chKey setChildStopped st

doRestartChild :: ChildSpec -> State -> Process State
doRestartChild spec state = do
  state'  <- addRestart state
  case state' of
    Nothing -> {- log it -} die $ ExitOther "ReachedMaxRestartIntensity"
    Just st -> do
      start <- doStartChild spec st
      case start of
        Left err      -> die $ "TODO: implement me"
        Right (_, s') -> return s'

addRestart :: State -> Process (Maybe State)
addRestart state = do
  now <- liftIO $ getCurrentTime
  let acc = foldl' (accRestarts now) [] (now:restarted)
  case length acc of
    n | n < maxAttempts -> return Nothing  -- TODO: logging/tracing/etc
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
        -- TODO: so this child isn't recognised!? WHAT DOES THAT MEAN?
        Nothing -> die "Internal Error"
        Just s' -> return $ Right $ (p, markActive s' p spec)
  where
    chKey = childKey spec

    chRunning :: ChildRef -> Child -> Prefix -> Suffix -> State -> Maybe State
    chRunning newRef (_, chSpec) prefix suffix st =
      Just $ (specs ^= prefix >< ((newRef, chSpec) <| suffix)) st

tryStartChild :: ChildSpec
              -> Process (Either StartFailure ChildRef)
tryStartChild spec =
  let proc = childRun spec in do
    mProc <- catch (unClosure proc >>= return . Right)
                   (\(e :: SomeException) -> return $ Left (show e))
    case mProc of
      Left err -> return $ Left (StartFailureBadClosure err)
      Right p  -> wrapClosure p >>= return . Right
  where wrapClosure :: Process ()
                    -> Process ChildRef
        wrapClosure proc = do
           supervisor <- getSelfPid
           pid <- spawnLocal $ do
             self <- getSelfPid
             link supervisor -- die if our parent dies
             () <- expect    -- wait for a start signal
             -- we translate `ExitShutdown' into a /normal/ exit
             (proc `catch` filterInitFailures supervisor self)
               `catchesExit` [
                   (\_ m -> handleMessageIf m (== ExitShutdown)
                                              (\_ -> return ()))
                 ]
           void $ monitor pid
           send pid ()
           return $ ChildRunning pid

        filterInitFailures :: ProcessId
                           -> ProcessId
                           -> ChildInitFailure
                           -> Process ()
        filterInitFailures sup pid ex = do
          case ex of
            ChildInitFailure _ -> liftIO $ throwIO ex
            ChildInitIgnore    -> MP.cast sup $ IgnoreChildReq pid

--------------------------------------------------------------------------------
-- Logging/Reporting                                                          --
--------------------------------------------------------------------------------

logShutdown :: ChildKey -> Process ()
logShutdown _ = return ()

--------------------------------------------------------------------------------
-- Accessors and State/Stats Utilities                                        --
--------------------------------------------------------------------------------

doAddChild :: AddChildReq -> Bool -> State -> AddChildRes
doAddChild (AddChild _ spec) update st =
  let chType = childType spec
  in case (findChild (childKey spec) st) of
       Just (ref, _) -> Exists ref
       Nothing ->
         case update of
           True  -> Added $ ( (specs ^: ((ChildStopped, spec) <|))
                           $ bumpStats Specified chType (+1) st
                           )
           False -> Added st

updateChild :: ChildKey
            -> (Child -> Prefix -> Suffix -> State -> Maybe State)
            -> State
            -> Maybe State
updateChild key updateFn state =
  let (prefix, suffix) = Seq.breakl ((== key) . childKey . snd) $ state ^. specs
  in
  case (Seq.viewl suffix) of
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
bumpStats Active    Worker     fn st = (bump fn) . (stats .> activeWorkers ^: fn) $ st
bumpStats Active    Supervisor fn st = (bump fn) . (stats .> activeSupervisors ^: fn) $ st

bump :: (Int -> Int) -> State -> State
bump with' = stats .> children ^: with'

isTemporary :: ChildRestart -> Bool
isTemporary = checkRestartType Temporary

isTransient :: ChildRestart -> Bool
isTransient = checkRestartType Transient

isIntrinsic :: ChildRestart -> Bool
isIntrinsic = checkRestartType Intrinsic

checkRestartType :: RestartPolicy -> ChildRestart -> Bool
checkRestartType r rType
  | (Restart r')          <- rType, r == r' = True
  | (DelayedRestart r' _) <- rType, r == r' = True
  | otherwise                               = False

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

supervisors :: Accessor SupervisorStats Int
supervisors = accessor _supervisors (\c st -> st { _supervisors = c })

activeWorkers :: Accessor SupervisorStats Int
activeWorkers = accessor _activeWorkers (\c st -> st { _activeWorkers = c })

activeSupervisors :: Accessor SupervisorStats Int
activeSupervisors = accessor _activeSupervisors (\c st -> st { _activeSupervisors = c })

