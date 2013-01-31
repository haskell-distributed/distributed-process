{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE BangPatterns         #-}

module SafeCounter
  ( startCounter,
    getCount,
    getCountAsync,
    incCount,
    resetCount,
    wait,
    waitTimeout
  ) where

import Control.Distributed.Process hiding (call, say)
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
  ( ProcessDefinition(..)
  , InitHandler
  , InitResult(..)
  , start
  , defaultProcess
  , condition
  )
import Control.Distributed.Process.Platform.ManagedProcess.Client
import Control.Distributed.Process.Platform.ManagedProcess.SafeServer
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data Increment = Increment
  deriving (Show, Typeable)
$(derive makeBinary ''Increment)

data Fetch = Fetch
  deriving (Show, Typeable)
$(derive makeBinary ''Fetch)

data Reset = Reset deriving (Show, Typeable)
$(derive makeBinary ''Reset)

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
        handleCallIf
          (condition (\count Increment -> count >= 10))-- invariant
          (\Increment -> halt :: RestrictedProcess Int (Result Int))

      , handleCall handleIncrement
      , handleCall (\Fetch     -> getState >>= reply)
      , handleCast (\Reset     -> putState (0 :: Int) >> continue)
      ]
   } :: ProcessDefinition State

halt :: forall s r . Serializable r => RestrictedProcess s (Result r)
halt = haltNoReply (TerminateOther "Count > 10")

handleIncrement :: Increment -> RestrictedProcess Int (Result Int)
handleIncrement Increment = do
  modifyState (+1)
  c <- getState
  say $ "state = " ++ (show c)
  reply c

