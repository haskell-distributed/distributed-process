{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Transport.QUIC.Internal.QUICTransport (
    -- * QUICTransport
    QUICTransport,
    newQUICTransport,
    foldOpenEndPoints,
    transportHost,
    transportPort,
    transportInputSocket,
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

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)
import Control.Exception (bracketOnError)
import Control.Monad.STM (atomically)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, (%~), (+~), (^.))
import Network.QUIC (Stream)
import Network.Socket (HostName, ServiceName, Socket)
import Network.Socket qualified as N
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
    , _transportInputSocket :: Socket
    , _transportState :: MVar TransportState
    }

data TransportState = TransportState
    { _localEndPoints :: !(Map EndPointId LocalEndPoint)
    , _nextEndPointId :: !EndPointId
    }

-- | Create a new QUICTransport
newQUICTransport :: HostName -> ServiceName -> IO QUICTransport
newQUICTransport host serviceName = do
    addr <- NE.head <$> N.getAddrInfo (Just N.defaultHints) (Just host) (Just serviceName)
    bracketOnError
        ( N.socket
            (N.addrFamily addr)
            N.Datagram -- QUIC is based on UDP
            N.defaultProtocol
        )
        N.close
        $ \socket -> do
            N.setSocketOption socket N.ReuseAddr 1
            N.withFdSocket socket N.setCloseOnExecIfNeeded
            N.bind socket (N.addrAddress addr)

            port <- N.socketPort socket
            QUICTransport
                host
                (show port)
                socket
                <$> newMVar (TransportState mempty 1)

data LocalEndPoint
    = Closed ClosedLocalEndPoint
    | Open OpenLocalEndPoint

newtype ClosedLocalEndPoint = ClosedLocalEndPoint
    {_closedLocalEndPointId :: EndPointId}

data OpenLocalEndPoint = OpenLocalEndPoint
    { _openLocalAddress :: !EndPointAddress
    , _openLocalEndPointId :: !EndPointId
    , _openLocalState :: !(MVar LocalEndPointState)
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
    {- ^ We identify connections by remote endpoint address, AND QUICStreamId,
    to support multiple connections between the same two endpoints
    -}
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

-- | Fold over all open local endpoitns of a transport
foldOpenEndPoints :: QUICTransport -> (OpenLocalEndPoint -> IO a) -> IO [a]
foldOpenEndPoints quicTransport f =
    readMVar (quicTransport ^. transportState)
        <&> flip (^.) localEndPoints
        <&> Map.elems
        <&> mapMaybe open
        >>= mapM f
  where
    open (Open openEndPoint) = Just openEndPoint
    open (Closed _) = Nothing

newLocalEndPoint :: QUICTransport -> TQueue Event -> IO OpenLocalEndPoint
newLocalEndPoint quicTransport newLocalQueue = do
    state <- readMVar (quicTransport ^. transportState)
    let newEndPointId = state ^. nextEndPointId

    newLocalState <- newMVar (LocalEndPointState mempty 0)
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

    -- I'm not sure how to resolve the race condition, whereby we could insert
    -- `newEndPointId` from two separate threads,
    modifyMVar_
        (quicTransport ^. transportState)
        ( \st ->
            pure $
                (st & localEndPoints %~ Map.insert newEndPointId (Open openEndpoint))
                    & nextEndPointId +~ 1
        )
    pure openEndpoint

closeLocalEndpoint ::
    QUICTransport ->
    OpenLocalEndPoint ->
    IO ()
closeLocalEndpoint quicTransport openEndPoint = do
    let endPointId = openEndPoint ^. openLocalEndPointId
     in do
            modifyMVar_
                (quicTransport ^. transportState)
                ( \st ->
                    pure $ st & localEndPoints %~ Map.adjust (\_ -> Closed (ClosedLocalEndPoint endPointId)) endPointId
                )
            atomically $ writeTQueue (openEndPoint ^. openLocalQueue) EndPointClosed
