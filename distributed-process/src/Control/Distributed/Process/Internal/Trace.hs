-- | Simple (internal) system logging/tracing support.
module Control.Distributed.Process.Internal.Trace
  ( Tracer
  , trace
  , traceFormat
  , defaultTracer
  , logfileTracer
  , stopTracer
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
  ( TQueue
  , newTQueueIO
  , readTQueue
  , writeTQueue
  , atomically
  )
import Control.Distributed.Process.Internal.Types (forever', Tracer(..))
import Control.Exception (catch, throwTo, AsyncException(ThreadKilled))
import Data.List (intersperse)
import Debug.Trace (traceEventIO)

import Prelude hiding (catch)

import System.Environment (getEnv)
import System.IO
  ( Handle
  , IOMode(AppendMode)
  , withFile
  , hPutStr
  )

defaultTracer :: IO Tracer
defaultTracer = do
  catch (getEnv "DISTRIBUTED_PROCESS_TRACE_FILE" >>= logfileTracer)
        (\(_ :: IOError) -> return (EventLogTracer traceEventIO))

logfileTracer :: FilePath -> IO Tracer
logfileTracer p = do
    q <- newTQueueIO
    tid <- forkIO $ withFile p AppendMode (\h -> logger h q)
    return $ LogFileTracer tid q
  where logger :: Handle -> TQueue String -> IO ()
        logger h q' = forever' $ do
          msg <- atomically $ readTQueue q'
          hPutStr h msg
          logger h q'

-- TODO: compatibility layer (conditional compilation?) for GHC/base versions

stopTracer :: Tracer -> IO ()
stopTracer (LogFileTracer tid _) = throwTo tid ThreadKilled -- cf killThread
stopTracer _                     = return ()

trace :: Tracer -> String -> IO ()
trace (LogFileTracer _ q) msg = atomically $ writeTQueue q msg
trace (EventLogTracer  t) msg = t msg

traceFormat :: Tracer
            -> String
            -> [String]
            -> IO ()
traceFormat t d ls = trace t $ concat (intersperse d ls)

