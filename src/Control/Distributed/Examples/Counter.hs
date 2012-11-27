{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
module Control.Distributed.Examples.Counter(
    startCounter,
    stopCounter,
    getCount,
    incCount,
    resetCount
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
    = CounterIncremented
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
startCounter count = startServer count defaultServer {
  msgHandlers = [
    handleCall handleCounter,
    handleCast handleReset
]}



-- | Stop the counter server
stopCounter :: ServerId -> Process ()
stopCounter sid = stopServer sid TerminateNormal



-- | Increment count
incCount :: ServerId -> Process ()
incCount sid = do
  CounterIncremented <- callServer sid NoTimeout IncrementCounter
  return ()



-- | Get the current count
getCount :: ServerId -> Process Int
getCount sid = do
  Count c <- callServer sid NoTimeout GetCount
  return c



-- | Reset the current count
resetCount :: ServerId -> Process ()
resetCount sid = castServer sid ResetCount


--------------------------------------------------------------------------------
-- IMPL                                                                       --
--------------------------------------------------------------------------------


handleCounter IncrementCounter = do
  modifyState (+1)
  count <- getState
  if count > 10
    then callStop CounterIncremented "Count > 10"
    else callOk CounterIncremented

handleCounter GetCount = do
  count <- getState
  callOk (Count count)


handleReset ResetCount = do
  putState 0
  castOk
