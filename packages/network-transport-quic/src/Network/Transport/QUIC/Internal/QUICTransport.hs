{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Transport.QUIC.Internal.QUICTransport (
    -- * QUICTransport
    QUICTransport,
    newQUICTransport,
    transportHost,
    transportPort,
    transportState,

    -- * TransportState
    TransportState,
    localEndPoints,
    nextEndPointId,

    -- * LocalEndPoint
    LocalEndPoint (Open, Closed),
    newLocalEndPoint,
    closeLocalEndpoint,

    -- ** ClosedLocalEndPoint
    ClosedLocalEndPoint,
    closedLocalEndPointId,

    -- * OpenLocalEndPoint
    OpenLocalEndPoint,
    openLocalAddress,
    openLocalEndPointId,
    openLocalState,
    openLocalQueue,

    -- * LocalEndPointState
    LocalEndPointState,
    localConnections,
    nextQUICStreamId,

    -- ** QUICStreamId
    QUICStreamId,

    -- * RemoteEndPoint
    RemoteEndPoint (RemoteEndPoint),
    remoteAddress,

    -- * Re-exports
    (^.),
) where

import Control.Concurrent.STM (TVar, modifyTVar', newTVar, newTVarIO, readTVar)
import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)
import Control.Monad (when)
import Control.Monad.STM (atomically, retry)
import Data.Function ((&))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, view, (%~), (+~), (^.))
import Network.Socket (HostName, ServiceName)
import Network.Transport (EndPointAddress, Event (EndPointClosed))
import Network.Transport.QUIC.Internal.QUICAddr (EndPointId, QUICAddr (..), encodeQUICAddr)

{- The QUIC transport has three levels of statefullness:

1. The transport itself

The transport contains state required to create new endpoints, and close them. This includes,
for example, a container of existing endpoints.

2. Endpoints

An endpoint has some state regarding the connections it has. An endpoint may have zero or more
connection, and must have state to be able to create new connections, and close existing ones.

3. Connections

Finally, each connection between endpoint has some state, needed to receive data.
-}

data QUICTransport = QUICTransport
    { _transportHost :: HostName
    , _transportPort :: ServiceName
    , _transportState :: TVar TransportState
    }

data TransportState = TransportState
    { _localEndPoints :: !(Map EndPointId LocalEndPoint)
    , _nextEndPointId :: !EndPointId
    }

-- | Create a new QUICTransport
newQUICTransport :: HostName -> ServiceName -> IO QUICTransport
newQUICTransport host port =
    QUICTransport
        host
        port
        <$> newTVarIO (TransportState mempty 1)

data LocalEndPoint
    = Closed ClosedLocalEndPoint
    | Open OpenLocalEndPoint

newtype ClosedLocalEndPoint = ClosedLocalEndPoint
    {_closedLocalEndPointId :: EndPointId}

data OpenLocalEndPoint = OpenLocalEndPoint
    { _openLocalAddress :: !EndPointAddress
    , _openLocalEndPointId :: !EndPointId
    , _openLocalState :: !(TVar LocalEndPointState)
    , _openLocalQueue :: !(TQueue Event)
    -- ^ Queue used to receive events
    }

{- | A QUICSteamId uniquely identifies a QUIC stream within the context of an endpoint.

NOTE: I tried to use the `StreamId` type from the `quic` library, but it was
clearly not unique per stream. I don't understand if this was intentional or not.
-}
newtype QUICStreamId = QUICStreamId Word32
    deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num)

data LocalEndPointState = LocalEndPointState
    { _localConnections :: Map (EndPointAddress, QUICStreamId) RemoteEndPoint
    -- ^ We identify connections by remote endpoint address, AND QUICStreamId,
    -- to support multiple connections between the same two endpoints
    , _nextQUICStreamId :: QUICStreamId
    }

newtype RemoteEndPoint = RemoteEndPoint
    { _remoteAddress :: EndPointAddress
    }

makeLenses ''QUICTransport
makeLenses ''TransportState
makeLenses ''ClosedLocalEndPoint
makeLenses ''OpenLocalEndPoint
makeLenses ''LocalEndPointState
makeLenses ''RemoteEndPoint

newLocalEndPoint :: QUICTransport -> TQueue Event -> IO OpenLocalEndPoint
newLocalEndPoint quicTransport newLocalQueue = atomically $ do
    state <- readTVar (quicTransport ^. transportState)
    let newEndPointId = state ^. nextEndPointId
        existingEndPoints = state ^. localEndPoints

    newLocalState <- newTVar (LocalEndPointState mempty 0)
    let openEndpoint =
            OpenLocalEndPoint
                { _openLocalAddress =
                    encodeQUICAddr
                        ( QUICAddr
                            (quicTransport ^. transportHost)
                            (quicTransport ^. transportPort)
                            newEndPointId
                        )
                , _openLocalEndPointId = newEndPointId
                , _openLocalState = newLocalState
                , _openLocalQueue = newLocalQueue
                }
        highestExistingEndPointId = maybe (newEndPointId - 1) (getEndPointId . fst) (Map.maxView existingEndPoints)
    when (highestExistingEndPointId >= newEndPointId) retry

    -- I'm not sure how to resolve the race condition, whereby we could insert
    -- `newEndPointId` from two separate threads,
    modifyTVar'
        (quicTransport ^. transportState)
        ( \st ->
            (st & localEndPoints %~ Map.insert newEndPointId (Open openEndpoint))
                & nextEndPointId +~ 1
        )
    pure openEndpoint
  where
    getEndPointId (Open op) = view openLocalEndPointId op
    getEndPointId (Closed cl) = view closedLocalEndPointId cl

closeLocalEndpoint ::
    QUICTransport ->
    OpenLocalEndPoint ->
    IO ()
closeLocalEndpoint quicTransport openEndPoint = do
    let endPointId = openEndPoint ^. openLocalEndPointId
    atomically $ do
        modifyTVar'
            (quicTransport ^. transportState)
            ( \st ->
                st & localEndPoints %~ Map.adjust (\_ -> Closed (ClosedLocalEndPoint endPointId)) endPointId
            )
        writeTQueue (openEndPoint ^. openLocalQueue) EndPointClosed
