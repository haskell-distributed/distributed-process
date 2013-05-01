{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE BangPatterns         #-}

module Counter
  ( startCounter,
    getCount,
    getCountAsync,
    incCount,
    resetCount,
    wait,
    waitTimeout
  ) where

import Control.Distributed.Process hiding (call)
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
import Control.Distributed.Process.Platform.Time
import Data.Binary
import Data.Typeable (Typeable)

import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- Call and Cast request types. Response types are unnecessary as the GenProcess
-- API uses the Async API, which in turn guarantees that an async handle can
-- /only/ give back a reply for that *specific* request through the use of an
-- anonymous middle-man (as the sender and reciever in our case).

data Increment = Increment
  deriving (Typeable, Generic, Eq, Show)
instance Binary Increment where

data Fetch = Fetch
  deriving (Typeable, Generic, Eq, Show)
instance Binary Fetch where

data Reset = Reset
  deriving (Typeable, Generic, Eq, Show)
instance Binary Reset where

type State = Int

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Increment count
incCount :: ProcessId -> Process Int
incCount sid = call sid Increment

-- | Get the current count - this is replicating what 'call' actually does
getCount :: ProcessId -> Process Int
getCount sid = call sid Fetch

-- | Get the current count asynchronously
getCountAsync :: ProcessId -> Process (Async Int)
getCountAsync sid = callAsync sid Fetch

-- | Reset the current count
resetCount :: ProcessId -> Process ()
resetCount sid = cast sid Reset

-- | Start a counter server
startCounter :: Int -> Process ProcessId
startCounter startCount =
  let server = serverDefinition
  in spawnLocal $ start startCount init' server >> return ()
  where init' :: InitHandler Int Int
        init' count = return $ InitOk count Infinity

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

serverDefinition :: ProcessDefinition State
serverDefinition = defaultProcess {
     apiHandlers = [
          handleCallIf (condition (\count Increment -> count >= 10))-- invariant
                       (\_ (_ :: Increment) -> do
                           haltNoReply_ (TerminateOther "Count > 10"))

        , handleCall handleIncrement
        , handleCall (\count Fetch -> reply count count)
        , handleCast (\_ Reset -> continue 0)
        ]
    } :: ProcessDefinition State

handleIncrement :: State -> Increment -> Process (ProcessReply State Int)
handleIncrement count Increment =
    let next = count + 1 in continue next >>= replyWith next

