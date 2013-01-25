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
import Control.Distributed.Process.Internal.Types
  ( forever'
  , Tracer(..)
  )
import Control.Exception
  ( catch
  , throwTo
  , SomeException
  , AsyncException(ThreadKilled)
  )
import Data.List (intersperse)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime)
import Debug.Trace (traceEventIO)

import Prelude hiding (catch)

import System.Environment (getEnv)
import System.IO
  ( Handle
  , IOMode(AppendMode)
  , BufferMode(..)
  , openFile
  , hClose
  , hPutStrLn
  , hSetBuffering
  )
import System.Locale (defaultTimeLocale)

defaultTracer :: IO Tracer
defaultTracer = do
  catch (getEnv "DISTRIBUTED_PROCESS_TRACE_FILE" >>= logfileTracer)
        (\(_ :: IOError) -> return (EventLogTracer traceEventIO))

logfileTracer :: FilePath -> IO Tracer
logfileTracer p = do
    q <- newTQueueIO
    h <- openFile p AppendMode
    hSetBuffering h LineBuffering
    tid <- forkIO $ logger h q `catch` (\(_ :: SomeException) ->
                                         hClose h >> return ())
    return $ LogFileTracer tid q h
  where logger :: Handle -> TQueue String -> IO ()
        logger h q' = forever' $ do
          msg <- atomically $ readTQueue q'
          now <- getCurrentTime
          hPutStrLn h $ msg ++ (formatTime defaultTimeLocale " - %c" now)

-- TODO: compatibility layer for GHC/base versions (e.g., where's killThread?)

stopTracer :: Tracer -> IO ()  -- overzealous but harmless duplication of hClose
stopTracer (LogFileTracer tid _ h) = throwTo tid ThreadKilled >> hClose h
stopTracer _                       = return ()

trace :: Tracer -> String -> IO ()
trace (LogFileTracer _ q _) msg = atomically $ writeTQueue q msg
trace (EventLogTracer t)    msg = t msg

traceFormat :: Tracer
            -> String
            -> [String]
            -> IO ()
traceFormat t d ls = trace t $ concat (intersperse d ls)

