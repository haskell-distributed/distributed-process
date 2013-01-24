
module Control.Distributed.Process.Internal.Trace
  ( Tracer
  , trace        -- :: String -> IO ()
  , traceFormat  -- :: (Show a) => (a -> a -> String) -> [a] -> IO ()
  , eventlog
  , console
  ) where

import Control.Concurrent
  ( ThreadId
  , forkIO
  )
import Control.Concurrent.STM
  ( TQueue
  , newTQueueIO
  , readTQueue
  , writeTQueue
  , atomically
  )
import Data.List (foldl')
import Debug.Trace
  ( traceEventIO
  )

data Tracer =
    ConsoleTracer ThreadId (TQueue String)
  | EventLogTracer (String -> IO ())

eventlog :: IO Tracer
eventlog = return $ EventLogTracer traceEventIO

console :: IO Tracer
console = do
  q <- newTQueueIO
  tid <- forkIO $ logger q
  return $ ConsoleTracer tid q
  where logger q' = do
          msg <- atomically $ readTQueue q'
          putStrLn msg
          logger q'

trace :: Tracer -> String -> IO ()
trace (ConsoleTracer _ q) msg = atomically $ writeTQueue q msg
trace (EventLogTracer  t) msg = t msg

traceFormat :: (Show a)
            => Tracer
            -> (String -> String -> String)
            -> [a]
            -> IO ()
traceFormat t f xs =
  trace t $ foldl' (\e a -> ((show e) `f` (show a))) "" xs
