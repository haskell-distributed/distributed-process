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
    nextConnectionCounter,

    -- ** ConnectionCounter
    ConnectionCounter,

    -- * RemoteEndPoint
    RemoteEndPoint (..),
    remoteEndPointAddress,
    remoteEndPointState,
    closeRemoteEndPoint,
    createRemoteEndPoint,
    createConnectionTo,

    -- ** Remote endpoint state
    RemoteEndPointState (..),
    ValidRemoteEndPointState (..),
    remoteStream,
    remoteStreamIsClosed,

    -- * Re-exports
    (^.),
) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, putMVar, readMVar)
import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)
import Control.Exception (bracketOnError, throwIO)
import Control.Monad.STM (atomically)
import Data.Function ((&))
import Data.Functor (($>), (<&>))
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, (%~), (+~), (^.))
import Network.QUIC (Stream)
import Network.Socket (HostName, ServiceName, Socket)
import Network.Socket qualified as N
import Network.TLS (Credential)
import Network.Transport (EndPointAddress, Event (EndPointClosed))
import Network.Transport.QUIC.Internal.Client (streamToEndpoint)
import Network.Transport.QUIC.Internal.Messaging (sendCloseConnection)
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

{- | A 'ConnectionCounter' uniquely identifies a connections within the context of an endpoint.
This allows to hold multiple separate connections between two endpoint addresses.

NOTE: I tried to use the `StreamId` type from the `quic` library, but it was
clearly not unique per stream. I don't understand if this was intentional or not.
-}
newtype ConnectionCounter = ConnectionCounter Word32
    deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num)

data LocalEndPointState = LocalEndPointState
    { _localConnections :: Map (EndPointAddress, ConnectionCounter) RemoteEndPoint
    {- ^ We identify connections by remote endpoint address, AND ConnectionCounter,
    to support multiple connections between the same two endpoint addresses
    -}
    , _nextConnectionCounter :: ConnectionCounter
    }

data RemoteEndPoint = RemoteEndPoint
    { _remoteEndPointAddress :: !EndPointAddress
    , _remoteEndPointState :: !(MVar RemoteEndPointState)
    }

data RemoteEndPointState
    = {- | In the short window between a connection
      being initiated and the handshake completing
      -}
      RemoteEndPointInit
    | RemoteEndPointValid ValidRemoteEndPointState
    | RemoteEndPointClosed

data ValidRemoteEndPointState = ValidRemoteEndPointState
    { _remoteStream :: Stream
    , _remoteStreamIsClosed :: MVar ()
    }

makeLenses ''QUICTransport
makeLenses ''TransportState
makeLenses ''ClosedLocalEndPoint
makeLenses ''OpenLocalEndPoint
makeLenses ''LocalEndPointState
makeLenses ''RemoteEndPoint
makeLenses ''ValidRemoteEndPointState

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
    modifyMVar_
        (quicTransport ^. transportState)
        ( \st -> do
            closeRemoteConnections
            pure $ st & localEndPoints %~ Map.adjust (\_ -> Closed (ClosedLocalEndPoint endPointId)) endPointId
        )
    atomically $ writeTQueue (openEndPoint ^. openLocalQueue) EndPointClosed
  where
    endPointId = openEndPoint ^. openLocalEndPointId
    closeRemoteConnections = modifyMVar_ (openEndPoint ^. openLocalState) $ \st -> do
        mapM_ (closeRemoteEndPoint endPointId) (st ^. localConnections)
        pure st

{- | Attempt to close a remote endpoint. If the remote endpoint is in
any non-valid state (e.g. already closed), then nothing happens.

Otherwise, a control message is sent to the remote end to nicely ask to
close this connection.
-}
closeRemoteEndPoint :: EndPointId -> RemoteEndPoint -> IO ()
closeRemoteEndPoint endPointId remoteEndPoint = modifyMVar_ (remoteEndPoint ^. remoteEndPointState) $
    \st -> case st of
        RemoteEndPointInit -> pure RemoteEndPointClosed
        RemoteEndPointClosed -> pure RemoteEndPointClosed
        RemoteEndPointValid (ValidRemoteEndPointState stream isClosed) ->
            sendCloseConnection stream endPointId
                >>= either
                    throwIO
                    ( \_ ->
                        putMVar isClosed ()
                            $> RemoteEndPointClosed
                    )

{- | Create a remote end point in the 'init' state.

The resulting remote end point is NOT set up, such that
it could be set up separately to /receive/ messages, or /send/ them.
-}
createRemoteEndPoint ::
    LocalEndPoint ->
    EndPointAddress ->
    IO (RemoteEndPoint, ConnectionCounter)
createRemoteEndPoint (Closed _) _ = throwIO (userError "uh")
createRemoteEndPoint (Open openLocalEndPoint) remoteAddress = do
    remoteEndPoint <- RemoteEndPoint remoteAddress <$> newMVar RemoteEndPointInit
    connCounter <- modifyMVar (openLocalEndPoint ^. openLocalState) $ \st -> do
        pure $
            ( st
                & localConnections %~ Map.insert (remoteAddress, st ^. nextConnectionCounter) remoteEndPoint
                & nextConnectionCounter +~ 1
            , st ^. nextConnectionCounter
            )

    pure (remoteEndPoint, connCounter)

{- | Create a remote end point, set up as a client that connects
to the remote 'EndPointAddress'.
-}
createConnectionTo ::
    NonEmpty Credential ->
    LocalEndPoint ->
    EndPointAddress ->
    IO RemoteEndPoint
createConnectionTo _ (Closed _) _ = throwIO (userError "uh")
createConnectionTo creds localEndPoint@(Open openLocalEndPoint) remoteAddress = do
    remoteEndPoint <- fst <$> createRemoteEndPoint localEndPoint remoteAddress

    streamToEndpoint creds (openLocalEndPoint ^. openLocalAddress) remoteAddress >>= \case
        Left _ -> throwIO (userError "uh")
        Right (closeStream, stream) -> do
            let validState =
                    RemoteEndPointValid $
                        ValidRemoteEndPointState
                            { _remoteStream = stream
                            , _remoteStreamIsClosed = closeStream
                            }
            modifyMVar_ (remoteEndPoint ^. remoteEndPointState) (\_ -> pure validState)
            pure remoteEndPoint