-- | Tracing/Debugging support - Trace Implementation
module Control.Distributed.Process.Internal.Trace.Tracer
  ( -- * API for the Node Controller
    traceController
    -- * Built in tracers
  , defaultTracer
  , systemLoggerTracer
  , logfileTracer
  , eventLogTracer
  ) where

import Control.Applicative ((<$>))
import Control.Concurrent.Chan (writeChan)
import Control.Concurrent.MVar
  ( MVar
  , putMVar
  )
import Control.Distributed.Process.Internal.CQueue
  ( CQueue
  )
import Control.Distributed.Process.Internal.Primitives
  ( catch
  , receiveWait
  , forward
  , sendChan
  , match
  , matchAny
  , matchAnyIf
  , handleMessage
  , matchUnknown
  , whereis
  , reregister, say, unwrapMessage
  )
import Control.Distributed.Process.Internal.Trace.Types
  ( TraceEvent(..)
  , SetTrace(..)
  , Addressable(..)
  , TraceSubject(..)
  , TraceFlags(..)
  , TraceOk(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Internal.Types
  ( LocalNode(..)
  , NCMsg(..)
  , ProcessId
  , Process
  , LocalProcess(..)
  , Identifier(..)
  , ProcessSignal(NamedSend)
  , Message
  , SendPort
  , forever'
  , nullProcessId
  , createUnencodedMessage
  )
import Control.Exception
  ( SomeException
  )

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map (Map)
import qualified Data.Map as Map

import Data.Maybe (fromMaybe)
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
import System.Mem.Weak
  ( Weak
  )

data TracerState = TracerST {
    client   :: !(Maybe ProcessId)
  , flags    :: !TraceFlags
  , regNames :: !(Map ProcessId (Set String))
  }

--------------------------------------------------------------------------------
-- Trace Handlers                                                             --
--------------------------------------------------------------------------------

defaultTracer :: Process ()
defaultTracer =
  catch (checkEnv "DISTRIBUTED_PROCESS_TRACE_FILE" >>= logfileTracer)
        (\(_ :: IOError) -> defaultTracerAux)

defaultTracerAux :: Process ()
defaultTracerAux =
  catch (checkEnv "DISTRIBUTED_PROCESS_TRACE_CONSOLE" >> systemLoggerTracer)
        (\(_ :: IOError) -> defaultEventLogTracer)

-- TODO: it would be /nice/ if we had some way of checking the runtime
-- options to see if +RTS -v (or similar) has been given...
defaultEventLogTracer :: Process ()
defaultEventLogTracer =
  catch (checkEnv "DISTRIBUTED_PROCESS_TRACE_EVENTLOG" >> eventLogTracer)
        (\(_ :: IOError) -> nullTracer)

checkEnv :: String -> Process String
checkEnv s = liftIO $ getEnv s

-- This trace client is (intentionally) useful - it simply provides
-- an intial client for the trace controller to talk to, until some
-- other (hopefully more useful) client is installed over the top of
-- it. This is the default trace client.
nullTracer :: Process ()
nullTracer = forever' $ receiveWait [ matchUnknown (return ()) ]

systemLoggerTracer :: Process ()
systemLoggerTracer = do
  node <- processNode <$> ask
  let tr = sendTraceMsg node
  forever' $ receiveWait [ matchAny (\m -> handleMessage m tr) ]
  where
    sendTraceMsg :: LocalNode -> TraceEvent -> Process ()
    sendTraceMsg node ev = do
      now <- liftIO $ getCurrentTime
      msg <- return $ (formatTime defaultTimeLocale "%c" now, (show ev))
      emptyPid <- return $ (nullProcessId (localNodeId node))
      traceMsg <- return $ NCMsg {
                             ctrlMsgSender = ProcessIdentifier (emptyPid)
                           , ctrlMsgSignal = (NamedSend "logger"
                                                 (createUnencodedMessage msg))
                           }
      liftIO $ writeChan (localCtrlChan node) traceMsg

eventLogTracer :: Process ()
eventLogTracer = do
  -- NB: when the GHC event log supports tracing arbitrary (ish) data, we will
  -- almost certainly use *that* facility independently of whether or not there
  -- is a tracer process installed. This is just a stop gap until then.
  forever' $ receiveWait [ matchAny (\m -> handleMessage m writeTrace) ]
  where
    writeTrace :: TraceEvent -> Process ()
    writeTrace ev = liftIO $ traceEventIO (show ev)

logfileTracer :: FilePath -> Process ()
logfileTracer p = do
  -- TODO: error handling if the handle cannot be opened
  h <- liftIO $ openFile p AppendMode
  liftIO $ hSetBuffering h LineBuffering
  logger h `catch` (\(_ :: SomeException) -> liftIO $ hClose h)
  where
    logger :: Handle -> Process ()
    logger h' = forever' $ do
      receiveWait [
          matchAnyIf (\ev -> case ev of
                               TraceEvDisable      -> True
                               (TraceEvTakeover _) -> True
                               _                   -> False)
                     (\_ -> (liftIO $ hClose h') >> error "trace stopped")
        , matchAny (\ev -> handleMessage ev (writeTrace h'))
        ]

    writeTrace :: Handle -> TraceEvent -> Process ()
    writeTrace h ev = do
      liftIO $ do
        now <- getCurrentTime
        hPutStrLn h $ (formatTime defaultTimeLocale "%c - " now) ++ (show ev)

--------------------------------------------------------------------------------
-- Tracer Implementation                                                      --
--------------------------------------------------------------------------------

traceController :: MVar ((Weak (CQueue Message))) -> Process ()
traceController mv = do
    -- This breach of encapsulation is deliberate: we don't want to tie up
    -- the node's internal control channel if we can possibly help it!
    weakQueue <- processWeakQ <$> ask
    liftIO $ putMVar mv weakQueue
    initialTracer <- whereis "tracer.initial"
    traceLoop initialState {
        client = initialTracer
      }
  where
    traceLoop :: TracerState -> Process ()
    traceLoop st = do
      -- Trace events are forwarded to the trace target when tracing is enabled.
      -- At some point in the future, we're going to start writing these custom
      -- events to the ghc eventlog, at which point this design might change.
      st' <- receiveWait [
          match (\(setResp, set :: SetTrace) -> do
                  -- We allow at most one trace client, which is a process id.
                  -- Tracking multiple clients represents too high an overhead,
                  -- so we leave that kind of thing to our consumers to figure
                  -- figure out.
                  case set of
                    (TraceEnable pid) -> do
                      -- notify the previous tracer it has been replaced
                      sendTrace st (createUnencodedMessage (TraceEvTakeover pid))
                      say $ "registering " ++ (show pid) ++ " as new tracer"
                      sendOk setResp
                      return st { client = (Just pid) }
                    TraceDisable -> do
                      sendTrace st (createUnencodedMessage TraceEvDisable)
                      sendOk setResp
                      say "setting sendTrace to noop"
                      return st { client = Nothing })
        , match (\(confResp, flags') ->
                  sendOk confResp >> applyTraceFlags flags' st)
        , match (\chGetFlags -> sendChan chGetFlags (flags st) >> return st)
        , match (\chGetCurrent -> sendChan chGetCurrent (client st) >> return st)
          -- we dequeue incoming events even if we don't process them
        , matchAny (\ev ->
                 handleMessage ev (handleTrace st ev) >>= return . fromMaybe st)
        ]
      traceLoop st'

    sendOk :: Maybe (SendPort TraceOk) -> Process ()
    sendOk Nothing   = return ()
    sendOk (Just sp) = sendChan sp TraceOk

    initialState :: TracerState
    initialState =
      TracerST
      { client   = Nothing
      , flags    = defaultTraceFlags
      , regNames = Map.empty
      }

-- note [runtime tracer control]
--
-- The trace mechanism is designed to put as little stress on the system, and
-- in particular the node controller, as possible. The LocalNode's @tracer@
-- field is therefore immutable, since we don't want to be blocking the node
-- controller when writing trace information out. The runtime cost of enabling
-- tracing is therefore the cost of enqueue for all trace-able operations at
-- all times. If tracing is not explicitly enabled, the trace record stored in
-- the local node state is matched and ignored in API calls, reducing the cost
-- to a single function call.
--
-- To /disable/ tracing facilities in a runtime system that has tracing enabled
-- then, is to instruct the tracer process not to forward any trace event data
-- and it is not possible to remove the runtime overhead (of enqueue in the
-- caller and dequeue + noop in the tracer process) once the node is started.

applyTraceFlags :: TraceFlags -> TracerState -> Process TracerState
applyTraceFlags flags' state = return state { flags = flags' }

handleTrace :: TracerState -> Message -> TraceEvent -> Process TracerState
handleTrace st _ (TraceEvRegistered p n) =
  let regNames' =
        Map.insertWith (\_ ns -> Set.insert n ns) p
                       (Set.singleton n)
                       (regNames st)
  in return st { regNames = regNames' }
handleTrace st _ (TraceEvUnRegistered p n) =
  let f ns = case ns of
               Nothing  -> Nothing
               Just ns' -> Just (Set.delete n ns')
      regNames' = Map.alter f p (regNames st)
  in return st { regNames = regNames' }
handleTrace st msg ev@(TraceEvSpawned  _)   = do
  traceEv ev msg (traceSpawned (flags st)) st >> return st
handleTrace st msg ev@(TraceEvDied _ _)     = do
  traceEv ev msg (traceDied (flags st)) st >> return st
handleTrace st msg ev@(TraceEvSent _ _ _)   =
  traceEv ev msg (traceSend (flags st)) st >> return st
handleTrace st msg ev@(TraceEvReceived _ _) =
  traceEv ev msg (traceRecv (flags st)) st >> return st
handleTrace st msg ev = do
  case ev of
    (TraceEvNodeDied _ _) ->
      case (traceNodes (flags st)) of
        True  -> sendTrace st msg
        False -> return ()
    (TraceEvUser _) -> do
      sendTrace st msg
    _ ->
      case (traceConnections (flags st)) of
        True  -> sendTrace st msg
        False -> return ()
  return st

traceEv :: TraceEvent
        -> Message
        -> Maybe TraceSubject
        -> TracerState
        -> Process ()
traceEv _  _   Nothing                  _  = return ()
traceEv _  msg (Just TraceAll)          st = sendTrace st msg
traceEv ev msg (Just (TraceProcs pids)) st = do
  node <- processNode <$> ask
  let p = case resolveToPid ev of
            Nothing  -> (nullProcessId (localNodeId node))
            Just pid -> pid
  case (Set.member p pids) of
    True  -> sendTrace st msg
    False -> return ()
traceEv ev msg (Just (TraceNames names)) st = do
  -- TODO: if we have recorded regnames for p, then we
  -- forward the trace iif there are overlapping trace targets
  node <- processNode <$> ask
  let p = case resolveToPid ev of
            Nothing  -> (nullProcessId (localNodeId node))
            Just pid -> pid
  case (Map.lookup p (regNames st)) of
    Nothing -> return ()
    Just ns -> if (Set.null (Set.intersection ns names))
                 then return ()
                 else sendTrace st msg

sendTrace :: TracerState -> Message -> Process ()
sendTrace st msg =
  let pid = (client st) in do
    (Just ev) <- unwrapMessage msg :: Process (Maybe TraceEvent)
    say ("sending " ++ (show ev) ++ " to " ++ (show pid))
    case pid of
      Just p  -> (flip forward) p msg
      Nothing -> return ()


