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
    LocalEndPoint,
    newLocalEndPoint,
    localAddress,
    localEndPointId,
    localState,
    localQueue,

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
import Control.Concurrent.STM.TQueue (TQueue)
import Control.Monad (when)
import Control.Monad.STM (atomically, retry)
import Data.Function ((&))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, view, (%~), (+~), (^.))
import Network.Socket (HostName, ServiceName)
import Network.Transport (EndPointAddress, Event)
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

data LocalEndPoint = LocalEndPoint
    { _localAddress :: !EndPointAddress
    , _localEndPointId :: !EndPointId
    , _localState :: !(TVar LocalEndPointState)
    , _localQueue :: !(TQueue Event)
    -- ^ Queue used to receive events
    }

{- | A QUICSteamId uniquely identifies a QUIC stream within the context of an endpoint.

NOTE: I tried to use the `StreamId` type from the `quic` library, but it was
clearly not unique per stream. I don't understand if this was intentional or not.
-}
newtype QUICStreamId = QUICStreamId Word32
    deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num)

data LocalEndPointState = LocalEndPointState
    { _localConnections :: Map EndPointAddress RemoteEndPoint
    , _nextQUICStreamId :: QUICStreamId
    }

newtype RemoteEndPoint = RemoteEndPoint
    { _remoteAddress :: EndPointAddress
    }

makeLenses ''QUICTransport
makeLenses ''TransportState
makeLenses ''LocalEndPoint
makeLenses ''LocalEndPointState
makeLenses ''RemoteEndPoint

newLocalEndPoint :: QUICTransport -> TQueue Event -> IO LocalEndPoint
newLocalEndPoint quicTransport newLocalQueue = atomically $ do
    state <- readTVar (quicTransport ^. transportState)
    let newEndPointId = state ^. nextEndPointId
        existingEndPoints = state ^. localEndPoints

    newLocalState <- newTVar (LocalEndPointState mempty 0)
    let endpoint =
            LocalEndPoint
                { _localAddress =
                    encodeQUICAddr
                        ( QUICAddr
                            (quicTransport ^. transportHost)
                            (quicTransport ^. transportPort)
                            newEndPointId
                        )
                , _localEndPointId = newEndPointId
                , _localState = newLocalState
                , _localQueue = newLocalQueue
                }
        highestExistingEndPointId = maybe (newEndPointId - 1) (view localEndPointId . fst) (Map.maxView existingEndPoints)
    when (highestExistingEndPointId >= newEndPointId) retry

    -- I'm not sure how to resolve the race condition, whereby we could insert
    -- `newEndPointId` from two separate threads,
    modifyTVar'
        (quicTransport ^. transportState)
        ( \st ->
            (st & localEndPoints %~ Map.insert newEndPointId endpoint)
                & nextEndPointId +~ 1
        )
    pure endpoint
