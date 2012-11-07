-- | Counter server example
--
-- Uses GenServer to implement a simple Counter process
--
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
module Control.Distributed.Examples.Counter (
    startCounter,
    getCount,
    resetCount
  ) where
import           Control.Concurrent
import           Data.Binary                            (Binary (..), getWord8,
                                                         putWord8)
import           Data.DeriveTH
import           Data.Typeable                          (Typeable)

import           Control.Distributed.Platform.GenServer
import           Control.Distributed.Process

--------------------------------------------------------------------------------
-- Data Types                                                                 --
--------------------------------------------------------------------------------

data CounterRequest
  = GetCount
  | ResetCount
    deriving (Typeable, Show)

$(derive makeBinary ''CounterRequest)

data CounterResponse
  = Count Int
  | CountReset
    deriving (Typeable, Show)

$(derive makeBinary ''CounterResponse)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- |
startCounter :: Name -> Int -> Process ProcessId
startCounter name count = do
  serverStart name (counterServer count)

-- | getCount
getCount :: ProcessId -> Process Int
getCount pid = do
  say $ "Get count for " ++ show pid
  from <- getSelfPid
  c <- serverCall pid (from, GetCount) NoTimeout
  say $ "Count is " ++ show c
  return c

-- | resetCount
resetCount :: ProcessId -> Process ()
resetCount pid = do
  say $ "Reset count for " ++ show pid
  from <- getSelfPid
  serverCall pid (from, ResetCount) NoTimeout :: Process ()
  return ()

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | Counter server
counterServer :: Int -> Process (Server CounterRequest CounterResponse)
counterServer count = do
  count <- liftIO $ newMVar count -- initialize state

  let handleCounterRequest :: CounterRequest -> Process (Maybe CounterResponse)
      handleCounterRequest GetCount = do
        n <- liftIO $ readMVar count
        return $ Just (Count n)
      handleCounterRequest ResetCount = do
        liftIO $ putMVar count 0
        return $ Just CountReset

  return defaultServer { handleCall = handleCounterRequest }
