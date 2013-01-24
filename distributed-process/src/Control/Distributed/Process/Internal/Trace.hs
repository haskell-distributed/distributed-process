-- | Simple (internal) system logging/tracing support.
module Control.Distributed.Process.Internal.Trace
  ( Tracer
  , trace
  , traceFormat
  , startEventlogTracer
  , startLogfileTracer
  , defaultTracer
  , stopTracer
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
import Control.Distributed.Process.Internal.Types (forever')
import Control.Exception
import Data.List (foldl')
import Debug.Trace (traceEventIO)
import System.IO

data Tracer =
    LogFileTracer ThreadId (TQueue String)
  | EventLogTracer (String -> IO ())
  | NoOpTracer

defaultTracer :: IO Tracer
defaultTracer = return NoOpTracer

startEventlogTracer :: IO Tracer
startEventlogTracer = return $ EventLogTracer traceEventIO

startLogfileTracer :: FilePath -> IO Tracer
startLogfileTracer p = do
    q <- newTQueueIO
    tid <- forkIO $ withFile p AppendMode (\h -> logger h q)
    return $ LogFileTracer tid q
  where logger :: Handle -> TQueue String -> IO ()
        logger h q' = forever' $ do
          msg <- atomically $ readTQueue q'
          hPutStr h msg
          logger h q'

stopTracer :: Tracer -> IO ()
stopTracer (LogFileTracer tid _) = throwTo tid ThreadKilled
stopTracer _                     = return ()

trace :: Tracer -> String -> IO ()
trace (LogFileTracer _ q) msg = atomically $ writeTQueue q msg
trace (EventLogTracer  t) msg = t msg
trace NoOpTracer          _   = return ()

traceFormat :: (Show a)
            => Tracer
            -> (String -> String -> String)
            -> [a]
            -> IO ()
traceFormat NoOpTracer _ _ = return ()
traceFormat t f xs =
  trace t $ foldl' (\e a -> ((show e) `f` (show a))) "" xs
