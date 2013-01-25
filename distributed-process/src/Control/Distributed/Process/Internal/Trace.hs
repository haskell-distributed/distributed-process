-- | Simple (internal) system logging/tracing support.
module Control.Distributed.Process.Internal.Trace
  ( Tracer
  , TraceArg(..)
  , trace
  , traceFormat
  , startTracing
  , stopTracer
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (writeChan)
import Control.Concurrent.STM
  ( TQueue
  , newTQueueIO
  , readTQueue
  , writeTQueue
  , atomically
  )
import Control.Distributed.Process.Internal.Types
  ( Tracer(..)
  , LocalNode(..)
  , NCMsg(..)
  , Identifier(ProcessIdentifier)
  , ProcessSignal(NamedSend)
  , forever'
  , nullProcessId
  , createMessage
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

data TraceArg = 
    TraceStr String
  | forall a. (Show a) => Trace a

startTracing :: LocalNode -> IO LocalNode
startTracing node = do
  tracer <- defaultTracer node
  return node { localTracer = tracer }

defaultTracer :: LocalNode -> IO Tracer
defaultTracer node = do
  catch (getEnv "DISTRIBUTED_PROCESS_TRACE_FILE" >>= logfileTracer)
        (\(_ :: IOError) -> defaultTracerAux node)

defaultTracerAux :: LocalNode -> IO Tracer
defaultTracerAux node = do
  catch (getEnv "DISTRIBUTED_PROCESS_TRACE_CONSOLE" >> procTracer node)
        (\(_ :: IOError) -> return (EventLogTracer traceEventIO))
  where procTracer :: LocalNode -> IO Tracer
        procTracer n = return $ (LocalNodeTracer n)

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
trace (LocalNodeTracer n)   msg = sendTraceMsg n msg
trace (EventLogTracer t)    msg = t msg
trace InactiveTracer        _   = return ()

traceFormat :: Tracer
            -> String
            -> [TraceArg]
            -> IO ()
traceFormat t d ls =
    trace t $ concat (intersperse d (map toS ls))
  where toS :: TraceArg -> String
        toS (TraceStr s) = s
        toS (Trace    a) = show a

sendTraceMsg :: LocalNode -> String -> IO ()
sendTraceMsg node string = do
  now <- getCurrentTime
  msg <- return $ (formatTime defaultTimeLocale "%c" now, string)
  emptyPid <- return $ (nullProcessId (localNodeId node))
  traceMsg <- return $ NCMsg {
                         ctrlMsgSender = ProcessIdentifier (emptyPid)
                       , ctrlMsgSignal = (NamedSend "logger" (createMessage msg))
                       }
  writeChan (localCtrlChan node) traceMsg

