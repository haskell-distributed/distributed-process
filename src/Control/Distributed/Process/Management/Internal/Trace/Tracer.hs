{-# LANGUAGE CPP  #-}
{-# LANGUAGE ScopedTypeVariables  #-}
-- | Tracing/Debugging support - Trace Implementation
module Control.Distributed.Process.Management.Internal.Trace.Tracer
  ( -- * API for the Management Agent
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
  , finally
  , die
  , receiveWait
  , forward
  , sendChan
  , match
  , matchAny
  , matchIf
  , handleMessage
  , matchUnknown
  )
import Control.Distributed.Process.Management.Internal.Types
  ( MxEvent(..)
  , Addressable(..)
  )
import Control.Distributed.Process.Management.Internal.Trace.Types
  ( SetTrace(..)
  , TraceSubject(..)
  , TraceFlags(..)
  , TraceOk(..)
  , defaultTraceFlags
  )
import Control.Distributed.Process.Management.Internal.Trace.Primitives
  ( traceOn )
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

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

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
#if MIN_VERSION_time(1,5,0)
import Data.Time.Format (defaultTimeLocale)
#else
import System.Locale (defaultTimeLocale)
#endif
import System.Mem.Weak
  ( Weak
  )

data TracerState =
  TracerST
  {
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

-- This trace client is (intentionally) a noop - it simply provides
-- an intial client for the trace controller to talk to, until some
-- other (hopefully more useful) client is installed over the top of
-- it. This is the default trace client.
nullTracer :: Process ()
nullTracer =
  forever' $ receiveWait [ matchUnknown (return ()) ]

systemLoggerTracer :: Process ()
systemLoggerTracer = do
  node <- processNode <$> ask
  let tr = sendTraceLog node
  forever' $ receiveWait [ matchAny (\m -> handleMessage m tr) ]
  where
    sendTraceLog :: LocalNode -> MxEvent -> Process ()
    sendTraceLog node ev = do
      now <- liftIO $ getCurrentTime
      msg <- return $ (formatTime defaultTimeLocale "%c" now, buildTxt ev)
      emptyPid <- return $ (nullProcessId (localNodeId node))
      traceMsg <- return $ NCMsg {
                             ctrlMsgSender = ProcessIdentifier (emptyPid)
                           , ctrlMsgSignal = (NamedSend "logger"
                                                 (createUnencodedMessage msg))
                           }
      liftIO $ writeChan (localCtrlChan node) traceMsg

    buildTxt :: MxEvent -> String
    buildTxt (MxLog msg) = msg
    buildTxt ev          = show ev

eventLogTracer :: Process ()
eventLogTracer =
  -- NB: when the GHC event log supports tracing arbitrary (ish) data, we will
  -- almost certainly use *that* facility independently of whether or not there
  -- is a tracer process installed. This is just a stop gap until then.
  forever' $ receiveWait [ matchAny (\m -> handleMessage m writeTrace) ]
  where
    writeTrace :: MxEvent -> Process ()
    writeTrace ev = liftIO $ traceEventIO (show ev)

logfileTracer :: FilePath -> Process ()
logfileTracer p = do
  -- TODO: error handling if the handle cannot be opened
  h <- liftIO $ openFile p AppendMode
  liftIO $ hSetBuffering h LineBuffering
  logger h `finally` (liftIO $ hClose h)
  where
    logger :: Handle -> Process ()
    logger h' = forever' $ do
      receiveWait [
          matchIf (\ev -> case ev of
                            MxTraceDisable      -> True
                            (MxTraceTakeover _) -> True
                            _                   -> False)
                  (\_ -> (liftIO $ hClose h') >> die "trace stopped")
        , matchAny (\ev -> handleMessage ev (writeTrace h'))
        ]

    writeTrace :: Handle -> MxEvent -> Process ()
    writeTrace h ev = do
      liftIO $ do
        now <- getCurrentTime
        hPutStrLn h $ (formatTime defaultTimeLocale "%c - " now) ++ (show ev)

--------------------------------------------------------------------------------
-- Tracer Implementation                                                      --
--------------------------------------------------------------------------------

traceController :: MVar ((Weak (CQueue Message))) -> Process ()
traceController mv = do
    -- See the documentation for mxAgentController for a
    -- commentary that explains this breach of encapsulation
    weakQueue <- processWeakQ <$> ask
    liftIO $ putMVar mv weakQueue
    initState <- initialState
    traceLoop initState { client = Nothing }
  where
    traceLoop :: TracerState -> Process ()
    traceLoop st = do
      let client' = client st
      -- Trace events are forwarded to the enabled trace target.
      -- At some point in the future, we're going to start writing these custom
      -- events to the ghc eventlog, at which point this design might change.
      st' <- receiveWait [
          match (\(setResp, set :: SetTrace) -> do
                  -- We consider at most one trace client, which is a process.
                  -- Tracking multiple clients represents too high an overhead,
                  -- so we leave that kind of thing to our consumers (e.g., the
                  -- high level Debug client module) to figure out.
                  case set of
                    (TraceEnable pid) -> do
                      -- notify the previous tracer it has been replaced
                      sendTraceMsg client' (createUnencodedMessage (MxTraceTakeover pid))
                      sendOk setResp
                      return st { client = (Just pid) }
                    TraceDisable -> do
                      sendTraceMsg client' (createUnencodedMessage MxTraceDisable)
                      sendOk setResp
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

    initialState :: Process TracerState
    initialState = do
      flags' <- checkEnvFlags
      return $ TracerST { client   = Nothing
                        , flags    = flags'
                        , regNames = Map.empty
                        }

    checkEnvFlags :: Process TraceFlags
    checkEnvFlags =
      catch (checkEnv "DISTRIBUTED_PROCESS_TRACE_FLAGS" >>= return . parseFlags)
            (\(_ :: IOError) -> return defaultTraceFlags)

    parseFlags :: String -> TraceFlags
    parseFlags s = parseFlags' s defaultTraceFlags
      where parseFlags' :: String -> TraceFlags -> TraceFlags
            parseFlags' [] parsedFlags = parsedFlags
            parseFlags' (x:xs) parsedFlags
              | x == 'p'  = parseFlags' xs parsedFlags { traceSpawned = traceOn }
              | x == 'n'  = parseFlags' xs parsedFlags { traceRegistered = traceOn }
              | x == 'u'  = parseFlags' xs parsedFlags { traceUnregistered = traceOn }
              | x == 'd'  = parseFlags' xs parsedFlags { traceDied = traceOn }
              | x == 's'  = parseFlags' xs parsedFlags { traceSend = traceOn }
              | x == 'r'  = parseFlags' xs parsedFlags { traceRecv = traceOn }
              | x == 'l'  = parseFlags' xs parsedFlags { traceNodes = True }
              | otherwise = parseFlags' xs parsedFlags

applyTraceFlags :: TraceFlags -> TracerState -> Process TracerState
applyTraceFlags flags' state = return state { flags = flags' }

handleTrace :: TracerState -> Message -> MxEvent -> Process TracerState
handleTrace st msg ev@(MxRegistered p n) =
  let regNames' =
        Map.insertWith (\_ ns -> Set.insert n ns) p
                       (Set.singleton n)
                       (regNames st)
  in do
    traceEv ev msg (traceRegistered (flags st)) st
    return st { regNames = regNames' }
handleTrace st msg ev@(MxUnRegistered p n) =
  let f ns = case ns of
               Nothing  -> Nothing
               Just ns' -> Just (Set.delete n ns')
      regNames' = Map.alter f p (regNames st)
  in do
    traceEv ev msg (traceUnregistered (flags st)) st
    return st { regNames = regNames' }
handleTrace st msg ev@(MxSpawned  _)   = do
  traceEv ev msg (traceSpawned (flags st)) st >> return st
handleTrace st msg ev@(MxProcessDied _ _)     = do
  traceEv ev msg (traceDied (flags st)) st >> return st
handleTrace st msg ev@(MxSent _ _ _)   =
  traceEv ev msg (traceSend (flags st)) st >> return st
handleTrace st msg ev@(MxReceived _ _) =
  traceEv ev msg (traceRecv (flags st)) st >> return st
handleTrace st msg ev = do
  case ev of
    (MxNodeDied _ _) ->
      case (traceNodes (flags st)) of
        True  -> sendTrace st ev msg
        False -> return ()
    (MxUser _) -> sendTrace st ev msg
    (MxLog _)  -> sendTrace st ev msg
    _ ->
      case (traceConnections (flags st)) of
        True  -> sendTrace st ev msg
        False -> return ()
  return st

traceEv :: MxEvent
        -> Message
        -> Maybe TraceSubject
        -> TracerState
        -> Process ()
traceEv _  _   Nothing                  _  = return ()
traceEv ev msg (Just TraceAll)          st = sendTrace st ev msg
traceEv ev msg (Just (TraceProcs pids)) st = do
  node <- processNode <$> ask
  let p = case resolveToPid ev of
            Nothing  -> (nullProcessId (localNodeId node))
            Just pid -> pid
  case (Set.member p pids) of
    True  -> sendTrace st ev msg
    False -> return ()
traceEv ev msg (Just (TraceNames names)) st = do
  -- if we have recorded regnames for p, then we forward the trace iif
  -- there are overlapping trace targets
  node <- processNode <$> ask
  let p = case resolveToPid ev of
            Nothing  -> (nullProcessId (localNodeId node))
            Just pid -> pid
  case (Map.lookup p (regNames st)) of
    Nothing -> return ()
    Just ns -> if (Set.null (Set.intersection ns names))
                 then return ()
                 else sendTrace st ev msg

sendTrace :: TracerState -> MxEvent -> Message -> Process ()
sendTrace st ev msg = do
  let c = client st
  if c == (resolveToPid ev)  -- we do not send the tracer events about itself...
     then return ()
     else sendTraceMsg c msg

sendTraceMsg :: Maybe ProcessId -> Message -> Process ()
sendTraceMsg Nothing  _   = return ()
sendTraceMsg (Just p) msg = (flip forward) p msg
