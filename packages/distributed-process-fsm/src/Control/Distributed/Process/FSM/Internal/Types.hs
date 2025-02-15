{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE PatternGuards              #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE RankNTypes                 #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.FSM.Internal.Types
-- Copyright   :  (c) Tim Watson 2017
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- Types and common functionality.
-----------------------------------------------------------------------------
module Control.Distributed.Process.FSM.Internal.Types
 ( apply
 , applyTransitions
 , State(..)
 , Transition(..)
 , Event(..)
 , Stopping(..)
 , resolveEvent
 , Step(..)
 , FSM(..)
 , runFSM
 , lift
 , liftIO
 , currentState
 , currentInput
 , currentMessage
 , stateData
 , addTransition
 , baseErr
 , decodeToEvent
 ) where

import Control.Distributed.Process
 ( Process
 , unwrapMessage
 , handleMessage
 , handleMessageIf
 , wrapMessage
 , die
 )
import qualified Control.Distributed.Process as P
 ( liftIO
 , Message
 )
import Control.Distributed.Process.Extras (ExitReason(..))
import Control.Distributed.Process.ManagedProcess
 ( Action
 , GenProcess
 , continue
 , stopWith
 , setProcessState
 , processState
 )
import qualified Control.Distributed.Process.ManagedProcess.Internal.GenProcess as Gen (enqueue, push)
import Control.Distributed.Process.ManagedProcess.Internal.Types
 ( Priority(..)
 )
import qualified Control.Distributed.Process.ManagedProcess.Internal.Types as MP
 ( lift
 )
import Control.Distributed.Process.ManagedProcess.Server.Priority (act)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO)
import qualified Control.Monad.State.Strict as ST
 ( MonadState
 , StateT
 , get
 , modify
 , lift
 , runStateT
 )
import Data.Binary
import Data.Maybe (fromJust, isJust)
import Data.Sequence
 ( Seq
 , ViewR(..)
 , (<|)
 , (|>)
 , viewr
 )
import qualified Data.Sequence as Q (null)
import Data.Typeable (Typeable, typeOf)
import Data.Tuple (swap, uncurry)
import GHC.Generics

-- | The internal state of an FSM process.
data State s d = (Show s, Eq s) =>
                 State { stName  :: s
                       , stData  :: d
                       , stProg  :: Step s d -- original program
                       , stInput :: Maybe P.Message
                       , stReply :: (P.Message -> Process ())
                       , stTrans :: Seq (Transition s d)
                       , stQueue :: Seq P.Message
                       }

instance forall s d . (Show s) => Show (State s d) where
 show State{..} = "State{stName=" ++ (show stName)
               ++ ", stTrans=" ++ (show stTrans) ++ "}"

-- | Represents a transition from one world state to another. Transitions can
-- be used to alter the process state, state data, to modify and/or interact with
-- the process mailbox, and to postpone processing of messages until state changes
-- take place.
--
-- The fundmental state transactions are @Remain@, @Enter newState@, and
-- @Stop exitReason@.
data Transition s d = Remain
                    | PutBack
                    | Push P.Message
                    | Enqueue P.Message
                    | Postpone
                    | Enter s
                    | Stop ExitReason
                    | Eval (GenProcess (State s d) ())

instance forall s d . (Show s) => Show (Transition s d) where
  show Remain    = "Remain"
  show PutBack   = "PutBack"
  show Postpone  = "Postpone"
  show (Push m)  = "Push " ++ (show m)
  show (Enqueue m) = "Enqueue " ++ (show m)
  show (Enter s) = "Enter " ++ (show s)
  show (Stop er) = "Stop " ++ (show er)
  show (Eval _)  = "Eval"

-- | Represents an event arriving, parameterised by the type @m@ of the event.
-- Used in a combinatorial style to wire FSM steps, actions and transitions to
-- specific types of input event.
data Event m where
  Wait    :: (Serializable m) => Event m
  WaitP   :: (Serializable m) => Priority () -> Event m
  Event   :: (Serializable m) => m -> Event m

-- | Event type wrapper passed to the FSM whenever we're shutting down.
data Stopping = Stopping { reason  :: ExitReason -- ^ The "ExitReason"
                         , errored :: Bool  -- ^ Was the shutdown triggered by an error
                         } deriving (Typeable, Generic, Show)
instance Binary Stopping where

-- | Resolve an event into a priority setting, for insertion into a priority queue.
resolveEvent :: forall s d m . (Serializable m)
             => Event m
             -> P.Message
             -> State s d
             -> m
             -> Process (Int, P.Message)
resolveEvent ev m _ _
  | WaitP p <- ev       = return (getPrio p, m)
  | otherwise           = return (0, m)

instance forall m . (Typeable m) => Show (Event m) where
  show ev@Wait      = show $ "Wait::" ++ (show $ typeOf ev)
  show ev@(WaitP _) = show $ "WaitP::" ++ (show $ typeOf ev)
  show ev           = show $ typeOf ev

-- | Represents a step in a FSM definition
data Step s d where
  Init      :: Step s d -> Step s d -> Step s d
  Yield     :: s -> d -> Step s d
  SafeWait  :: (Serializable m) => Event m -> Step s d -> Step s d
  Await     :: (Serializable m) => Event m -> Step s d -> Step s d
  Always    :: (Serializable m) => (m -> FSM s d (Transition s d)) -> Step s d
  Perhaps   :: (Eq s) => s -> FSM s d (Transition s d) -> Step s d
  Matching  :: (Serializable m) => (m -> Bool) -> (m -> FSM s d (Transition s d)) -> Step s d
  Sequence  :: Step s d -> Step s d -> Step s d
  Alternate :: Step s d -> Step s d -> Step s d
  Reply     :: (Serializable r) => FSM s d r -> Step s d

instance forall s d . (Show s) => Show (Step s d) where
  show st
    | Init      _ _ <- st = "Init"
    | Yield     _ _ <- st = "Yield"
    | Await     _ s <- st = "Await (_ " ++ (show s) ++ ")"
    | SafeWait  _ s <- st = "SafeWait (_ " ++ (show s) ++ ")"
    | Always    _   <- st = "Always _"
    | Perhaps   s _ <- st = "Perhaps (" ++ (show s) ++ ")"
    | Matching  _ _ <- st = "Matching _ _"
    | Sequence  a b <- st = "Sequence [" ++ (show a) ++ " |> " ++ (show b) ++ "]"
    | Alternate a b <- st = "Alternate [" ++ (show a) ++ " .| " ++ (show b) ++ "]"
    | Reply     _   <- st = "Reply"

-- | State monad transformer.
newtype FSM s d o = FSM {
   unFSM :: ST.StateT (State s d) Process o
 }
 deriving ( Functor
          , Monad
          , ST.MonadState (State s d)
          , MonadIO
          , MonadFix
          , Typeable
          , Applicative
          )

-- | Run an action in the @FSM@ monad.
runFSM :: State s d -> FSM s d o -> Process (o, State s d)
runFSM state proc = ST.runStateT (unFSM proc) state

-- | Lift an action in the @Process@ monad to @FSM@.
lift :: Process a -> FSM s d a
lift p = FSM $ ST.lift p

-- | Lift an IO action directly into @FSM@, @liftIO = lift . Process.LiftIO@.
liftIO :: IO a -> FSM s d a
liftIO = lift . P.liftIO

-- | Fetch the state for the current pass.
currentState :: FSM s d s
currentState = ST.get >>= return . stName

-- | Fetch the state data for the current pass.
stateData :: FSM s d d
stateData = ST.get >>= return . stData

-- | Fetch the message that initiated the current pass.
currentMessage :: forall s d . FSM s d P.Message
currentMessage = ST.get >>= return . fromJust . stInput

-- | Retrieve the 'currentMessage' and attempt to decode it to type @m@
currentInput :: forall s d m . (Serializable m) => FSM s d (Maybe m)
currentInput = currentMessage >>= \m -> lift (unwrapMessage m :: Process (Maybe m))

-- | Add a "Transition" to be evaluated once the current pass completes.
addTransition :: Transition s d -> FSM s d ()
addTransition t = ST.modify (\s -> fromJust $ enqueue s (Just t) )

{-# INLINE seqEnqueue #-}
seqEnqueue :: Seq a -> a -> Seq a
seqEnqueue s a = a <| s

{-# INLINE seqPush #-}
seqPush :: Seq a -> a -> Seq a
seqPush s a = s |> a

{-# INLINE seqPop #-}
seqPop :: Seq a -> Maybe (a, Seq a)
seqPop s = maybe Nothing (\(s' :> a) -> Just (a, s')) $ getR s

{-# INLINE getR #-}
getR :: Seq a -> Maybe (ViewR a)
getR s =
  case (viewr s) of
    EmptyR -> Nothing
    a      -> Just a

enqueue :: State s d -> Maybe (Transition s d) -> Maybe (State s d)
enqueue st@State{..} trans
  | isJust trans = Just $ st { stTrans = seqPush stTrans (fromJust trans) }
  | otherwise    = Nothing

apply :: (Show s) => State s d -> P.Message -> Step s d -> Process (Maybe (State s d))
apply st msg step
  | Init      is  ns  <- step = do
      -- ensure we only `init` successfully once
      -- P.liftIO $ putStrLn "Init _ _"
      st' <- apply st msg is
      case st' of
        Just s  -> apply (s { stProg = ns }) msg ns
        Nothing -> die $ ExitOther $ baseErr ++ ":InitFailed"
  | Yield     sn  sd  <- step = do
      -- P.liftIO $ putStrLn "Yield s d"
      return $ Just $ st { stName = sn, stData = sd }
  | SafeWait evt act' <- step = do
      let ev = decodeToEvent evt msg
      -- P.liftIO $ putStrLn $ (show evt) ++ " decoded: " ++ (show $ isJust ev)
      if isJust (ev) then apply st msg act'
                     else {-(P.liftIO $ putStrLn $ "Cannot decode " ++ (show (evt, msg))) >>  -}
                          return Nothing
  | Await     evt act' <- step = do
      let ev = decodeToEvent evt msg
      -- P.liftIO $ putStrLn $ (show evt) ++ " decoded: " ++ (show $ isJust ev)
      if isJust (ev) then apply st msg act'
                     else {- (P.liftIO $ putStrLn $ "Cannot decode " ++ (show (evt, msg))) >>  -}
                          return Nothing
  | Always    fsm      <- step = do
      -- P.liftIO $ putStrLn "Always..."
      runFSM st (handleMessage msg fsm) >>= mstash
  | Perhaps   eqn act' <- step = do
      -- P.liftIO $ putStrLn $ "Perhaps " ++ (show eqn) ++ " in " ++ (show $ stName st)
      if eqn == (stName st) then runFSM st act' >>= stash
                            else return Nothing
  | Matching  chk fsm  <- step = do
      -- P.liftIO $ putStrLn "Matching..."
      runFSM st (handleMessageIf msg chk fsm) >>= mstash
  | Sequence  ac1 ac2 <- step = do s <- apply st msg ac1
                                   -- P.liftIO $ putStrLn $ "Seq LHS valid: " ++ (show $ isJust s)
                                   if isJust s then apply (fromJust s) msg ac2
                                               else return Nothing
  | Alternate al1 al2 <- step = do s <- apply st msg al1
                                   -- P.liftIO $ putStrLn $ "Alt LHS valid: " ++ (show $ isJust s)
                                   if isJust s then return s
                                               else apply st msg al2
  | Reply     rply    <- step = do
      let ev = Eval $ do fSt <- processState
                         s' <- MP.lift $ do (r, s) <- runFSM fSt rply
                                            (stReply s) $ wrapMessage r
                                            return s
                         setProcessState s'
      -- (_, st') <- runFSM st (addTransition ev)
      return $ enqueue st (Just ev)
  | otherwise = error $ baseErr ++ ".Internal.Types.apply:InvalidStep"
  where
    mstash = return . uncurry enqueue . swap
    stash (o, s) = return $ enqueue s (Just o)

applyTransitions :: forall s d. (Show s)
                 => State s d
                 -> [GenProcess (State s d) ()]
                 -> Action (State s d)
applyTransitions st@State{..} evals
  | Q.null stTrans, [] <- evals = continue $ st
  | Q.null stTrans = act $ do setProcessState st
                              -- MP.liftIO $ putStrLn $ "ProcessState: " ++ (show stName)
                              mapM_ id evals
  | (tr, st2) <- next
  , PutBack   <- tr = applyTransitions st2 ((Gen.enqueue $ fromJust stInput) : evals)
  | isJust stInput
  , input     <- fromJust stInput
  , (tr, st2) <- next
  , Postpone  <- tr = applyTransitions (st2 { stQueue = seqEnqueue stQueue input }) evals
  | (tr, st2) <- next
  , Enqueue m <- tr = applyTransitions st2 ((Gen.enqueue m):evals)
  | (tr, st2) <- next
  , Push m    <- tr = applyTransitions st2 ((Gen.push m):evals)
  | (tr, st2) <- next
  , Eval proc <- tr = applyTransitions st2 (proc:evals)
  | (tr, st2) <- next
  , Remain    <- tr = applyTransitions st2 evals
  | (tr, _)   <- next
  , Stop  er  <- tr = stopWith st er
  | (tr, st2) <- next
  , Enter s   <- tr =
      if s == stName then applyTransitions st2 evals
                     else do let st' = st2 { stName = s }
                             let evals' = if Q.null stQueue then evals
                                                            else (mapM_ Gen.push stQueue) : evals
                             applyTransitions st' evals'
  | otherwise = error $ baseErr ++ ".Internal.Process.applyTransitions:InvalidTransition"
  where
    -- don't call if Q.null!
    next = let (t, q) = fromJust $ seqPop stTrans
           in (t, st { stTrans = q })

-- | Base module name for error messages.
baseErr :: String
baseErr = "Control.Distributed.Process.FSM"

-- | Given an "Event" for any "Serializable" type @m@ and a raw message, decode
-- the message and map it to either @Event m@ if the types are aligned, otherwise
-- @Nothing@.
decodeToEvent :: Serializable m => Event m -> P.Message -> Maybe (Event m)
decodeToEvent Wait         msg = unwrapMessage msg >>= fmap Event
decodeToEvent (WaitP _)    msg = unwrapMessage msg >>= fmap Event
decodeToEvent ev@(Event _) _   = Just ev  -- it's a bit odd that we'd end up here....
