{-# LANGUAGE DeriveDataTypeable   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE ScopedTypeVariables  #-}

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
import Control.Distributed.Process.Platform.Async
import Control.Distributed.Process.Platform.GenProcess
import Control.Distributed.Process.Platform.Time
import Data.Binary
import Data.DeriveTH
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

-- Call and Cast request types. Response types are unnecessary as the GenProcess
-- API uses the Async API, which in turn guarantees that an async handle can
-- /only/ give back a reply for that *specific* request through the use of an
-- anonymous middle-man (as the sender and reciever in our case).

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
getCount sid = getCountAsync sid >>= wait >>= unpack
  where unpack :: AsyncResult Int -> Process Int
        unpack (AsyncDone i) = return i
        unpack asyncOther    = die asyncOther

-- | Get the current count asynchronously
getCountAsync :: ProcessId -> Process (Async Int)
getCountAsync sid = callAsync sid Fetch

-- | Reset the current count
resetCount :: ProcessId -> Process ()
resetCount sid = cast sid Reset

--------------------------------------------------------------------------------
-- Implementation                                                             --
--------------------------------------------------------------------------------

-- | Start a counter server
startCounter :: Int -> Process ProcessId
startCounter startCount =
  let server = defaultProcess {
     dispatchers = [
          handleCallIf (state (\count -> count <= 10))   -- invariant
                       (\_ (_ :: Increment) ->
                            noReply_ (TerminateOther "Count > 10"))

        , handleCall handleIncrement
        , handleCall (\count (_ :: Fetch) -> reply count count)
        , handleCast (\_ Fetch -> continue 0)
        ]
    } :: ProcessDefinition State
  in spawnLocal $ start startCount init' server >> return ()
  where init' :: InitHandler Int Int
        init' count = return $ InitOk count Infinity

handleIncrement :: State -> Increment -> Process (ProcessReply State Int)
handleIncrement count _ =
    let newCount = count + 1 in do
    next <- continue newCount
    replyWith newCount next

