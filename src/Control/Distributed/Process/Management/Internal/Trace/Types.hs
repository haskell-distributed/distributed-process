{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE GADTs  #-}
{-# LANGUAGE DeriveGeneric  #-}

-- | Tracing/Debugging support - Types
module Control.Distributed.Process.Management.Internal.Trace.Types
  ( SetTrace(..)
  , TraceSubject(..)
  , TraceFlags(..)
  , TraceArg(..)
  , TraceOk(..)
  , traceLog
  , traceLogFmt
  , traceEvent
  , traceMessage
  , defaultTraceFlags
  , enableTrace
  , enableTraceSync
  , disableTrace
  , disableTraceSync
  , getTraceFlags
  , setTraceFlags
  , setTraceFlagsSync
  , getCurrentTraceClient
  ) where

import Control.Distributed.Process.Internal.Types
  ( MxEventBus(..)
  , ProcessId
  , SendPort
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Management.Internal.Bus
  ( publishEvent
  )
import Control.Distributed.Process.Management.Internal.Types
  ( MxEvent(..)
  )
import Control.Distributed.Process.Serializable
import Data.Binary
import Data.List (intersperse)
import Data.Set (Set)
import qualified Data.Set as Set (fromList)
import Data.Typeable
import GHC.Generics

--------------------------------------------------------------------------------
-- Types                                                                      --
--------------------------------------------------------------------------------

data SetTrace = TraceEnable !ProcessId | TraceDisable
  deriving (Typeable, Generic, Eq, Show)
instance Binary SetTrace where

-- | Defines which processes will be traced by a given 'TraceFlag',
-- either by name, or @ProcessId@. Choosing @TraceAll@ is /by far/
-- the most efficient approach, as the tracer process therefore
-- avoids deciding whether or not a trace event is viable.
--
data TraceSubject =
    TraceAll                     -- enable tracing for all running processes
  | TraceProcs !(Set ProcessId)  -- enable tracing for a set of processes
  | TraceNames !(Set String)     -- enable tracing for a set of named/registered processes
  deriving (Typeable, Generic, Show)
instance Binary TraceSubject where

-- | Defines /what/ will be traced. Flags that control tracing of
-- @Process@ events, take a 'TraceSubject' controlling which processes
-- should generate trace events in the target process.
data TraceFlags = TraceFlags {
    traceSpawned      :: !(Maybe TraceSubject) -- filter process spawned tracing
  , traceDied         :: !(Maybe TraceSubject) -- filter process died tracing
  , traceRegistered   :: !(Maybe TraceSubject) -- filter process registration tracing
  , traceUnregistered :: !(Maybe TraceSubject) -- filter process un-registration
  , traceSend         :: !(Maybe TraceSubject) -- filter process/message tracing by sender
  , traceRecv         :: !(Maybe TraceSubject) -- filter process/message tracing by receiver
  , traceNodes        :: !Bool                 -- enable node status trace events
  , traceConnections  :: !Bool                 -- enable connection status trace events
  } deriving (Typeable, Generic, Show)
instance Binary TraceFlags where

defaultTraceFlags :: TraceFlags
defaultTraceFlags =
  TraceFlags {
    traceSpawned      = Nothing
  , traceDied         = Nothing
  , traceRegistered   = Nothing
  , traceUnregistered = Nothing
  , traceSend         = Nothing
  , traceRecv         = Nothing
  , traceNodes        = False
  , traceConnections  = False
  }

data TraceArg =
    TraceStr String
  | forall a. (Show a) => Trace a

-- | A generic 'ok' response from the trace coordinator.
data TraceOk = TraceOk
  deriving (Typeable, Generic)
instance Binary TraceOk where

--------------------------------------------------------------------------------
-- Internal/Common API                                                        --
--------------------------------------------------------------------------------

traceLog :: MxEventBus -> String -> IO ()
traceLog tr s = publishEvent tr (unsafeCreateUnencodedMessage $ MxLog s)

traceLogFmt :: MxEventBus
            -> String
            -> [TraceArg]
            -> IO ()
traceLogFmt t d ls =
  traceLog t $ concat (intersperse d (map toS ls))
  where toS :: TraceArg -> String
        toS (TraceStr s) = s
        toS (Trace    a) = show a

traceEvent :: MxEventBus -> MxEvent -> IO ()
traceEvent tr ev = publishEvent tr (unsafeCreateUnencodedMessage ev)

traceMessage :: Serializable m => MxEventBus -> m -> IO ()
traceMessage tr msg = traceEvent tr (MxUser (unsafeCreateUnencodedMessage msg))

enableTrace :: MxEventBus -> ProcessId -> IO ()
enableTrace t p =
  publishEvent t (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                                (TraceEnable p)))

enableTraceSync :: MxEventBus -> SendPort TraceOk -> ProcessId -> IO ()
enableTraceSync t s p =
  publishEvent t (unsafeCreateUnencodedMessage (Just s, TraceEnable p))

disableTrace :: MxEventBus -> IO ()
disableTrace t =
  publishEvent t (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     TraceDisable))

disableTraceSync :: MxEventBus -> SendPort TraceOk -> IO ()
disableTraceSync t s =
  publishEvent t (unsafeCreateUnencodedMessage ((Just s), TraceDisable))

setTraceFlags :: MxEventBus -> TraceFlags -> IO ()
setTraceFlags t f =
  publishEvent t (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)), f))

setTraceFlagsSync :: MxEventBus -> SendPort TraceOk -> TraceFlags -> IO ()
setTraceFlagsSync t s f =
  publishEvent t (unsafeCreateUnencodedMessage ((Just s), f))

getTraceFlags :: MxEventBus -> SendPort TraceFlags -> IO ()
getTraceFlags t s = publishEvent t (unsafeCreateUnencodedMessage s)

getCurrentTraceClient :: MxEventBus -> SendPort (Maybe ProcessId) -> IO ()
getCurrentTraceClient t s = publishEvent t (unsafeCreateUnencodedMessage s)

class Traceable a where
  uod :: [a] -> TraceSubject

instance Traceable ProcessId where
  uod = TraceProcs . Set.fromList

instance Traceable String where
  uod = TraceNames . Set.fromList
