{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
module Control.Distributed.Examples.Counter(
   CounterId,
    startCounter,
    stopCounter,
    getCount,
    resetCount
  ) where
import           Control.Concurrent
import           Data.Typeable                           (Typeable)

import           Control.Distributed.Platform.GenServer
import           Control.Distributed.Process
import           Data.Binary                             (Binary (..), getWord8,
                                                          putWord8)
import           Data.DeriveTH

--------------------------------------------------------------------------------
-- API                                                                        --
--------------------------------------------------------------------------------

-- | The Counter id
type CounterId = ServerId

-- call
data CounterRequest
    = IncrementCounter
    | GetCount
        deriving (Show, Typeable)
$(derive makeBinary ''CounterRequest)

data CounterResponse
    = CounterIncremented
    | Count Int
        deriving (Show, Typeable)
$(derive makeBinary ''CounterResponse)

-- cast
data ResetCount = ResetCount deriving (Show, Typeable)
$(derive makeBinary ''ResetCount)

-- |
startCounter :: Process ServerId
startCounter = startServer $ defaultServer { msgHandlers = [
   handleCall handleCounter,
   handleCast handleReset
]}

stopCounter :: ServerId -> Process ()
stopCounter sid = stopServer sid TerminateNormal

-- | getCount
getCount :: ServerId -> Process Int
getCount counterId = do
  reply <- callServer counterId GetCount NoTimeout
  case reply of
    Count value -> do
      say $ "Count is " ++ show value
      return value
    _ -> error "Shouldnt be here!" -- TODO tighten the types to avoid this

-- | resetCount
resetCount :: ServerId -> Process ()
resetCount counterId = do
  say $ "Reset count for " ++ show counterId
  castServer counterId ResetCount

--------------------------------------------------------------------------------
-- IMPL                                                                       --
--------------------------------------------------------------------------------

handleCounter IncrementCounter = return $ CallOk (CounterIncremented)
handleCounter GetCount = return $ CallOk (Count 0)

handleReset ResetCount = return $ CastOk
