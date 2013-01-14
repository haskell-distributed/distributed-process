{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}

module Control.Distributed.Process.Platform.Supervisor 
  ( foo
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Platform.GenProcess
import Control.Distributed.Process.Platform.Internal.Types
import Control.Distributed.Process.Platform.Time

import Data.Binary
import Data.DeriveTH
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import Prelude hiding (init)

{-
-export([start_link/2,start_link/3,
     start_child/2, restart_child/2,
     delete_child/2, terminate_child/2,
     which_children/1, find_child/2,
     check_childspecs/1]).
-}

-- TODO: we need process id *and* monitor refs, plus all the startup info

type ChildId = Int

newtype Child = Child ProcessId
    deriving (Eq, Show, Typeable)
$(derive makeBinary ''Child)

defaultChild :: Child
defaultChild = Child (undefined :: ProcessId)

data ChildKey = ChildKey !ChildId !Child
    deriving (Typeable, Show)
$(derive makeBinary ''ChildKey)

instance Eq ChildKey where
  (ChildKey x _) == (ChildKey y _) = x == y

instance Ord ChildKey where
  (ChildKey x _) `compare` (ChildKey y _) = x `compare` y

data ChildSpec = ChildSpec
    deriving (Typeable, Show)
$(derive makeBinary ''ChildSpec)

-- | Supervisor's state - most of our lookups are id based
data State = State {
    specs :: Map.Map ChildKey ChildSpec
  , maxId :: Int
  }

toPid :: ChildKey -> ProcessId
toPid (ChildKey _ (Child p)) = p

foo :: Process ()
foo = undefined

-- callback API

handleLookupChild :: State
                  -> ChildKey
                  -> Process (ProcessReply State (Maybe ChildSpec))
handleLookupChild state key = reply (spec state key) state
  where spec :: State -> ChildKey -> Maybe ChildSpec 
        spec s k = Map.lookup k (specs s)

handleAddChild :: State
               -> ChildSpec
               -> Process (ProcessReply State (Maybe ChildKey))
handleAddChild state spec =
  let childId = nextKey state
  in do
    child <- tryStartChild childId spec
    case child of
      err@(Left _) -> reply Nothing state
      Right key -> store key spec state{ maxId = childId } >>= reply (Just key)              

tryStartChild :: ChildId
              -> ChildSpec
              -> Process (Either TerminateReason ChildKey)
tryStartChild childId spec = undefined

store :: ChildKey -> ChildSpec -> State -> Process State
store key spec state =
  let specs' = Map.insert key spec (specs state) 
  in return state{ specs = specs' }

nextKey :: State -> Int
nextKey = (+1) . maxId

-- GenProcess API

supInit :: InitHandler [String] State
supInit _ = return $ InitOk State { specs = Map.empty, maxId = 0 } Infinity

supServer :: Behaviour State
supServer = Behaviour {
     dispatchers = [
         handleCall handleLookupChild
       ]
   , infoHandlers = []
   , timeoutHandler = undefined
   , terminateHandler = undefined
   , unhandledMessagePolicy = Drop 
   }
