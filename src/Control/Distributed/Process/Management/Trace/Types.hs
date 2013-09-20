{-# LANGUAGE DeriveGeneric  #-}

-- | Tracing/Debugging support - Types
module Control.Distributed.Process.Management.Trace.Types
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

import Control.Applicative ((<$>), (<*>))
import Control.Distributed.Process.Internal.CQueue (enqueue)
import Control.Distributed.Process.Internal.Types
  ( MxEventBus(..)
  , Tracer(..)
  , NodeId
  , ProcessId
  , DiedReason
  , Message
  , SendPort
  , unsafeCreateUnencodedMessage
  )
import Control.Distributed.Process.Management.Bus
  ( enqueueEvent
  )
import Control.Distributed.Process.Management.Types
  ( MxEvent(..)
  , Addressable(..)
  )
import Control.Distributed.Process.Serializable
import Data.Binary
import Data.Foldable (forM_)
import Data.List (intersperse)
import Data.Set (Set)
import qualified Data.Set as Set (fromList)
import Data.Typeable
import GHC.Generics
import System.Mem.Weak (deRefWeak)
import Network.Transport
  ( ConnectionId
  , EndPointAddress
  )

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

traceLog :: Tracer -> String -> IO ()
traceLog (Tracer _ wqRef) s = enqueueEvent wqRef (unsafeCreateUnencodedMessage $ MxLog s)

traceLogFmt :: Tracer
            -> String
            -> [TraceArg]
            -> IO ()
traceLogFmt t d ls =
  traceLog t $ concat (intersperse d (map toS ls))
  where toS :: TraceArg -> String
        toS (TraceStr s) = s
        toS (Trace    a) = show a

traceEvent :: Tracer -> MxEvent -> IO ()
traceEvent (Tracer _ wqRef) ev = enqueueEvent wqRef (unsafeCreateUnencodedMessage ev)

traceMessage :: Serializable m => Tracer -> m -> IO ()
traceMessage tr msg = traceEvent tr (MxUser (unsafeCreateUnencodedMessage msg))

enableTrace :: Tracer -> ProcessId -> IO ()
enableTrace (Tracer _ wqRef) p =
  enqueueEvent wqRef (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                                    (TraceEnable p)))

enableTraceSync :: Tracer -> SendPort TraceOk -> ProcessId -> IO ()
enableTraceSync (Tracer _ wqRef) s p =
  enqueueEvent wqRef (unsafeCreateUnencodedMessage (Just s, TraceEnable p))

disableTrace :: Tracer -> IO ()
disableTrace (Tracer _ wqRef) =
  enqueueEvent wqRef (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)),
                                     TraceDisable))

disableTraceSync :: Tracer -> SendPort TraceOk -> IO ()
disableTraceSync (Tracer _ wqRef) s =
  enqueueEvent wqRef (unsafeCreateUnencodedMessage ((Just s), TraceDisable))

setTraceFlags :: Tracer -> TraceFlags -> IO ()
setTraceFlags (Tracer _ wqRef) f =
  enqueueEvent wqRef (unsafeCreateUnencodedMessage ((Nothing :: Maybe (SendPort TraceOk)), f))

setTraceFlagsSync :: Tracer -> SendPort TraceOk -> TraceFlags -> IO ()
setTraceFlagsSync (Tracer _ wqRef) s f =
  enqueueEvent wqRef (unsafeCreateUnencodedMessage ((Just s), f))

getTraceFlags :: Tracer -> SendPort TraceFlags -> IO ()
getTraceFlags (Tracer _ wqRef) s = enqueueEvent wqRef (unsafeCreateUnencodedMessage s)

getCurrentTraceClient :: Tracer -> SendPort (Maybe ProcessId) -> IO ()
getCurrentTraceClient (Tracer _ wqRef) s = enqueueEvent wqRef (unsafeCreateUnencodedMessage s)

class Traceable a where
  uod :: [a] -> TraceSubject

instance Traceable ProcessId where
  uod = TraceProcs . Set.fromList

instance Traceable String where
  uod = TraceNames . Set.fromList

