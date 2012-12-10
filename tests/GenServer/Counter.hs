{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
module GenServer.Counter(
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
startCounter count = startServer count defaultServer {
    initHandler = do
      --c <- getState
      --trace $ "Counter init: " ++ show c
      initOk Infinity,
    terminateHandler = \r ->
      --const (return ()),
      trace $ "Counter terminate: " ++ show r,
    handlers = [
      handle handleCounter,
      handle handleReset
    ]
}



-- | Stop the counter server
stopCounter :: ServerId -> Process ()
stopCounter sid = stopServer sid ()



-- | Increment count
incCount :: ServerId -> Process Int
incCount sid = do
    CounterIncremented c <- callServer sid Infinity IncrementCounter
    return c



-- | Get the current count
getCount :: ServerId -> Process Int
getCount sid = do
    Count c <- callServer sid Infinity GetCount
    return c



-- | Reset the current count
resetCount :: ServerId -> Process ()
resetCount sid = castServer sid ResetCount


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
