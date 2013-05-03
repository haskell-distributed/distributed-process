{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE BangPatterns               #-}

module Control.Distributed.Process.Platform.Supervisor
  ( ChildKey
  , ChildType(..)
  , ChildSpec(..)
  , MaxRestarts
  , maxRestarts
  , RestartLimit(..)
  , defaultLimits
  , RestartStrategy(..)
  , ChildRef(..)
  , RestartPolicy(..)
  , ChildRestart(..)
  , SupervisorStats(..)
  , StaticLabel
  , StartFailure(..)
  , DeleteChildResult(..)
  , Child
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
import Control.Distributed.Process.Platform.ManagedProcess
  ( call
  , handleCall
  , handleInfo
  , reply
  , continue
  , input
  , defaultProcess
  , InitHandler
  , InitResult(..)
  , ProcessAction
  , ProcessReply
  , ProcessDefinition(..)
  , UnhandledMessagePolicy(Drop)
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP (start)
import Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted
  ( RestrictedProcess
  , Result
  , getState
  , putState
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted as Restricted
  ( handleCallIf
  , handleCall
  , reply
  )
-- import Control.Distributed.Process.Platform.ManagedProcess.Server.Unsafe
-- import Control.Distributed.Process.Platform.ManagedProcess.Server
import Control.Distributed.Process.Platform.Time
import Control.Exception (SomeException)

import Control.Monad.Error

import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  , (.>)
  , (^=)
  , (^.)
  )
-- import qualified Data.Accessor.Container as DAC
import Data.Binary
import Data.Foldable (find, foldlM, toList)
import Data.Map (Map)
import qualified Data.Map as Map -- TODO: use Data.Map.Strict
import Data.Sequence (Seq, ViewL(EmptyL, (:<)), (<|), (><), filter)
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)
import Prelude hiding (filter, init, rem)

import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- external client/configuration API

newtype MaxRestarts = MaxR { maxR :: Int }
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
data RestartLimit = RestartLimit
                      !MaxRestarts  -- ^ maximum bound on the number of restarts
                      !TimeInterval -- ^ time interval within which the bound is applied
  deriving (Typeable, Generic, Show)
instance Binary RestartLimit where

defaultLimits :: RestartLimit
defaultLimits = RestartLimit (MaxR 0) (seconds 1)

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
    RestartNone               !RestartLimit -- ^ restart only the failed child process
  | RestartAllSiblings        !RestartLimit -- ^ also restart all siblings
  | RestartPriorSiblings      !RestartLimit -- ^ restart prior siblings (i.e., prior in /start order/)
  | RestartSubsequentSiblings !RestartLimit -- ^ restart subsequent siblings (i.e., subsequent in /start order/)
  deriving (Typeable, Generic, Show)
instance Binary RestartStrategy where

-- | Identifies a child process by name.
type ChildKey = String

-- | A reference to a (possibly running) child.
data ChildRef =
    ChildRunning !ProcessId    -- ^ a reference to the (currently running) child
  | ChildRestarting !ProcessId -- ^ a reference to the /old/ (previous) child, which is now restarting
  | ChildStopped               -- ^ indicates the child is not currently running
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
  , childRun     :: !(Closure (Process TerminateReason))
    -- NOTE: TerminateReason - we install an exit handler for TerminateShutdown
    -- and anything other than TerminateNormal will get thrown
  } deriving (Typeable, Generic, Show)
instance Binary ChildSpec where

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
    StartFailureDuplicateChild -- ^ a child with this 'ChildKey' already exists
  | StartFailureAlreadyRunning -- ^ the child is already up and running
  | StartFailureBadClosure !StaticLabel -- ^ a closure cannot be resolved by RTS
  deriving (Typeable, Generic, Show)
instance Binary StartFailure where

-- | The result of a call to 'removeChild'.
data DeleteChildResult =
    ChildDeleted              -- ^ the child specification was successfully removed
  | ChildNotFound             -- ^ the child specification was not found
  | ChildNotStopped !ChildRef -- ^ the child was not removed, as it was not stopped.
  deriving (Typeable, Generic, Show)
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

data AddChildResult = Exists ChildRef | Added State

data AddChildResp =
    ChildAdded         !ChildRef
  | ChildAlreadyExists !ChildRef
  | ChildFailedToStart !StartFailure
  deriving (Typeable, Generic, Show)
instance Binary AddChildResp where

type ChildSpecs = Seq Child

data StatsType = Active | Specified

data State = State {
    _specs   :: ChildSpecs
  , _active  :: Map ProcessId ChildKey
  , strategy :: RestartStrategy
  , _stats   :: SupervisorStats
  }

--------------------------------------------------------------------------------
-- Public API                                                                 --
--------------------------------------------------------------------------------

-- start/specify

start :: RestartStrategy -> [ChildSpec] -> Process ProcessId
start strategy' specs' = do
  spawnLocal $ MP.start (strategy', specs') supInit serverDefinition >> return ()

-- client API

statistics :: Addressable a => a -> Process (SupervisorStats)
statistics = (flip call) StatsReq

lookupChild :: Addressable a => a -> ChildKey -> Process (Maybe ChildSpec)
lookupChild addr key = call addr $ FindReq key

listChildren :: Addressable a => a -> Process [Child]
listChildren addr = call addr ListReq

addChild :: Addressable a => a -> ChildSpec -> Process (Maybe ChildKey)
addChild addr spec = call addr $ AddChild False spec

deleteChild :: Addressable a => a -> ChildKey -> Process DeleteChildResult
deleteChild addr spec = call addr $ DeleteChild spec

startChild :: Addressable a
           => a
           -> ChildSpec
           -> Process (Either StartFailure ChildKey)
startChild addr spec = call addr $ AddChild True spec

restartChild :: Addressable a
             => a
             -> ChildKey
             -> Process (Either StartFailure ChildRef)
restartChild sid _ = call sid $ "RestartChildReq"

--------------------------------------------------------------------------------
-- ManagedProcess / Internal API                                              --
--------------------------------------------------------------------------------

supInit :: InitHandler (RestartStrategy, [ChildSpec]) State
supInit (strategy', specs') =
  let initState = emptyState { strategy = strategy' }
  in (foldlM initChild initState specs' >>= return . (flip InitOk) Infinity)
       `catch` \(e :: SomeException) -> return $ InitFail (show e)
  where initChild :: State -> ChildSpec -> Process State
        initChild st ch = tryStartChild ch >>= initialised st ch

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

emptyState :: State
emptyState = State {
    _specs    = Seq.empty
  , _active   = Map.empty
  , strategy = RestartAllSiblings $ defaultLimits
  , _stats   = emptyStats
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

serverDefinition :: ProcessDefinition State
serverDefinition = defaultProcess {
     apiHandlers = [
         Restricted.handleCall   handleLookupChild
       , Restricted.handleCall   handleListChildren
       , Restricted.handleCall   handleDeleteChild
       , Restricted.handleCallIf
             (input (\(AddChild immediate _) -> immediate == False))
             handleAddChild
       , handleCall        handleStartChild
       , Restricted.handleCall   handleGetStats
       ]
   , infoHandlers = [handleInfo handleMonitorSignal]
   , terminateHandler = \_ _ -> return ()
   , unhandledMessagePolicy = Drop
   } :: ProcessDefinition State

handleLookupChild :: FindReq
                  -> RestrictedProcess State (Result (Maybe (ChildRef, ChildSpec)))
handleLookupChild (FindReq key) = getState >>= Restricted.reply . findChild key

handleListChildren :: ListReq
                   -> RestrictedProcess State (Result [Child])
handleListChildren _ = getState >>= Restricted.reply . toList . (^. specs)

handleAddChild :: AddChildReq
               -> RestrictedProcess State (Result AddChildResp)
handleAddChild req = getState >>= return . doAddChild req >>= doReply
  where doReply :: AddChildResult -> RestrictedProcess State (Result AddChildResp)
        doReply (Added  s) = putState s >> Restricted.reply (ChildAdded ChildStopped)
        doReply (Exists e) = Restricted.reply (ChildAlreadyExists e)

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
                     . (bump decrement)
                     $ bumpStats Specified (childType spec) decrement st
                     )
          Restricted.reply ChildDeleted
      | otherwise = Restricted.reply $ ChildNotStopped ref

handleStartChild :: State
                 -> AddChildReq
                 -> Process (ProcessReply AddChildResp State)
handleStartChild state req@(AddChild _ spec) =
  let added = doAddChild req state in
  case added of
    Exists e      -> reply (ChildAlreadyExists e) state
    Added  state' -> attemptStart state' spec
  where
    attemptStart st ch = do
      started <- tryStartChild ch
      case started of
        Left err  -> reply (ChildFailedToStart err) $ removeChild spec st
        Right ref -> reply (ChildAdded ref) $ markActive st ref ch

handleGetStats :: StatsReq
               -> RestrictedProcess State (Result SupervisorStats)
handleGetStats _ = Restricted.reply . (^. stats) =<< getState

-- info APIs

handleMonitorSignal :: State
                    -> ProcessMonitorNotification
                    -> Process (ProcessAction State)
handleMonitorSignal state (ProcessMonitorNotification _ pid _reason) =
  let (cId, active') =
        Map.updateLookupWithKey (\_ _ -> Nothing) pid $ state ^. active
      mSpec = case cId of
                Nothing -> Nothing
                Just c  -> findChild c state
  in do
    -- restart it
    -- change the state
    -- bump stats
    say $ "hmn, what to do with " ++ (show mSpec)
    continue $ active ^= active' $ state

-- working with child processes

tryStartChild :: ChildSpec
              -> Process (Either StartFailure ChildRef)
tryStartChild spec =
  let proc = childRun spec in do
    mProc <- catch (unClosure proc >>= return . Right)
                   (\(e :: SomeException) -> return $ Left (show e))
    case mProc of
      Left err -> return $ Left (StartFailureBadClosure err)
      Right p  -> wrapClosure p spec
  where wrapClosure :: Process TerminateReason
                    -> ChildSpec
                    -> Process (Either StartFailure ChildRef)
        wrapClosure proc spec' =
          let chId = childKey spec' in do
            supervisor <- getSelfPid
            pid <- spawnLocal $ do
              link supervisor -- die if our parent dies
              () <- expect    -- wait for a start signal
              proc >>= checkExitType chId
            void $ monitor pid
            send pid ()
            return $ Right $ ChildRunning pid

        checkExitType :: ChildKey -> TerminateReason -> Process ()
        checkExitType _       r@(TerminateOther _) = die r
        checkExitType childId TerminateShutdown    = logShutdown childId
        checkExitType _       TerminateNormal      = return ()

-- managing internal state

doAddChild :: AddChildReq -> State -> AddChildResult
doAddChild (AddChild _ spec) st =
  let chType = childType spec
  in case (findChild (childKey spec) st) of
       Just (ref, _) -> Exists ref
       Nothing       -> Added $ ( (specs ^: ((ChildStopped, spec) <|))
                                $ bumpStats Specified chType (+1) st
                                )

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

active :: Accessor State (Map ProcessId ChildKey)
active = accessor _active (\act' st -> st { _active = act' })

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

logShutdown :: ChildKey -> Process ()
logShutdown _ = return ()

