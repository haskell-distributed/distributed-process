{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE DeriveGeneric        #-}

module SafeCounter
  ( startCounter,
    getCount,
    getCountAsync,
    incCount,
    resetCount,
    wait,
    waitTimeout,
    Fetch(..),
    Increment(..),
    Reset(..)
  ) where

import Control.Distributed.Process hiding (call, say)
import Control.Distributed.Process.Platform
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.ManagedProcess
  ( ProcessDefinition(..)
  , InitHandler
  , InitResult(..)
  , defaultProcess
  , condition
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as ManagedProcess (serve)
import Control.Distributed.Process.Platform.ManagedProcess.Client
import Control.Distributed.Process.Platform.ManagedProcess.Server.Restricted
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Serializable
import Data.Binary
import Data.Typeable (Typeable)
import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data Increment = Increment
  deriving (Show, Typeable, Generic)
instance Binary Increment where

data Fetch = Fetch
  deriving (Show, Typeable, Generic)
instance Binary Fetch where

data Reset = Reset deriving (Show, Typeable, Generic)
instance Binary Reset where

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Increment count
incCount :: ProcessId -> Process Int
incCount sid = call sid Increment

-- | Get the current count
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
  in spawnLocal $ ManagedProcess.serve startCount init' server
  where init' :: InitHandler Int Int
        init' count = return $ InitOk count Infinity

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

serverDefinition :: ProcessDefinition Int
serverDefinition = defaultProcess {
   apiHandlers = [
        handleCallIf
          (condition (\count Increment -> count >= 10)) -- invariant
          (\Increment -> halt :: RestrictedProcess Int (Result Int))

      , handleCall handleIncrement
      , handleCall (\Fetch -> getState >>= reply)
      , handleCast (\Reset -> putState (0 :: Int) >> continue)
      ]
   } :: ProcessDefinition Int

halt :: forall s r . Serializable r => RestrictedProcess s (Result r)
halt = haltNoReply (ExitOther "Count > 10")

handleIncrement :: Increment -> RestrictedProcess Int (Result Int)
handleIncrement _ = modifyState (+1) >> getState >>= reply

