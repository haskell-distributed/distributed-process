{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
module GenServer.Counter(
    startCounter,
    terminateCounter,
    getCount,
    getCountAsync,
    incCount,
    resetCount,
    wait,
    waitTimeout,
    Timeout(..)
  ) where

import           Control.Distributed.Platform.GenServer

import           Data.Binary                            (Binary (..), getWord8,
                                                         putWord8)
import           Data.DeriveTH
import           Data.Typeable                          (Typeable)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- Call request(s)
data CounterRequest
    = IncrementCounter
    | GetCount
        deriving (Show, Typeable)
$(derive makeBinary ''CounterRequest)

-- Call response(s)
data CounterResponse
    = CounterIncremented Int
    | Count Int
        deriving (Show, Typeable)
$(derive makeBinary ''CounterResponse)

-- Cast message(s)
data ResetCount = ResetCount deriving (Show, Typeable)
$(derive makeBinary ''ResetCount)

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | Start a counter server
startCounter :: Int -> Process ServerId
startCounter count = start count defaultServer {
    initHandler = do
      --c <- getState
      --trace $ "Counter init: " ++ show c
      initOk Infinity,
    terminateHandler = const (return ()),
      -- \r -> trace $ "Counter terminate: " ++ show r,
    handlers = [
      handle handleCounter,
      handle handleReset
    ]
}

-- | Stop the counter server
terminateCounter :: ServerId -> Process ()
terminateCounter sid = terminate sid ()

-- | Increment count
incCount :: ServerId -> Process Int
incCount sid = do
    CounterIncremented c <- call sid Infinity IncrementCounter
    return c

-- | Get the current count
getCount :: ServerId -> Process Int
getCount sid = do
    Count c <- call sid Infinity GetCount
    return c

-- | Get the current count asynchronously
getCountAsync :: ServerId -> Process (Async Int)
getCountAsync sid = callAsync sid GetCount

-- | Reset the current count
resetCount :: ServerId -> Process ()
resetCount sid = cast sid ResetCount

--------------------------------------------------------------------------------
-- IMPL                                                                       --
--------------------------------------------------------------------------------

handleCounter :: Handler Int CounterRequest CounterResponse
handleCounter IncrementCounter = do
    modifyState (+1)
    count <- getState
    if count > 10
      then stop (CounterIncremented count) "Stopping because 'Count > 10'"
      else ok (CounterIncremented count)
handleCounter GetCount = do
    count <- getState
    ok (Count count)

handleReset :: Handler Int ResetCount ()
handleReset ResetCount = do
    putState 0
    ok ()
