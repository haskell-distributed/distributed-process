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
import           Data.Typeable                          (Typeable)

import           Control.Distributed.Platform.GenServer
import           Control.Distributed.Process
import           Data.Binary                            (Binary (..), getWord8,
                                                         putWord8)
import           Data.DeriveTH

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

-- | The Counter id
type CounterId = ServerId

-- |
startCounter :: Name -> Int -> Process CounterId
startCounter name count =
  serverStart name (counterServer count)

-- | getCount
getCount :: CounterId -> Process Int
getCount counterId = do
  say $ "Get count for " ++ show counterId
  reply <- serverCall counterId GetCount NoTimeout
  case reply of
    Count value -> do
      say $ "Count is " ++ show value
      return value
    _ -> error "Shouldnt be here!" -- TODO tighten the types to avoid this

-- | resetCount
resetCount :: CounterId -> Process ()
resetCount counterId = do
  say $ "Reset count for " ++ show counterId
  reply <- serverCall counterId ResetCount NoTimeout
  case reply of
    CountReset -> return ()
    _ -> error "Shouldn't be here!" -- TODO tighten the types to avoid this

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | Counter server
counterServer :: Int -> Process (Server CounterRequest CounterResponse)
counterServer count = do
  count <- liftIO $ newMVar count -- initialize state

  let handleCounterRequest :: CounterRequest -> Process (CallResult CounterResponse)
      handleCounterRequest GetCount = do
        n <- liftIO $ readMVar count 
        return $ CallOk (Count n)
      handleCounterRequest ResetCount = do
        liftIO $ swapMVar count 0
        return $ CallOk CountReset

  return defaultServer {
    handleCall = handleCounterRequest
  } :: Process (Server CounterRequest CounterResponse)
