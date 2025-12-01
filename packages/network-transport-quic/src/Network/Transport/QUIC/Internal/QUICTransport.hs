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
    TransportState (..),
    localEndPoints,
    nextEndPointId,

    -- * LocalEndPoint
    LocalEndPoint,
    localAddress,
    localEndPointId,
    localEndPointState,
    localQueue,
    newLocalEndPoint,
    closeLocalEndpoint,

    -- * LocalEndPointState
    LocalEndPointState (..),
    ValidLocalEndPointState,
    localConnections,
    nextConnectionCounter,

    -- ** ConnectionCounter
    ConnectionCounter,

    -- * RemoteEndPoint
    RemoteEndPoint (..),
    remoteEndPointAddress,
    remoteEndPointId,
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
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, (%~), (+~), (^.))
import Network.QUIC (Stream)
import Network.Socket (HostName, ServiceName, Socket)
import Network.Socket qualified as N
import Network.TLS (Credential)
import Network.Transport (ConnectErrorCode (ConnectFailed, ConnectNotFound), EndPointAddress, Event (EndPointClosed), NewEndPointErrorCode (NewEndPointFailed), TransportError (TransportError))
import Network.Transport.QUIC.Internal.Client (streamToEndpoint)
import Network.Transport.QUIC.Internal.Messaging (sendCloseConnection)
import Network.Transport.QUIC.Internal.QUICAddr (EndPointId, QUICAddr (..), decodeQUICAddr, encodeQUICAddr)

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

data TransportState
    = TransportStateValid ValidTransportState
    | TransportStateClosed

data ValidTransportState = ValidTransportState
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
                <$> newMVar (TransportStateValid $ ValidTransportState mempty 1)

data LocalEndPoint = OpenLocalEndPoint
    { _localAddress :: !EndPointAddress
    , _localEndPointId :: !EndPointId
    , _localEndPointState :: !(MVar LocalEndPointState)
    , _localQueue :: !(TQueue Event)
    -- ^ Queue used to receive events
    }

{- | A 'ConnectionCounter' uniquely identifies a connections within the context of an endpoint.
This allows to hold multiple separate connections between two endpoint addresses.

NOTE: I tried to use the `StreamId` type from the `quic` library, but it was
clearly not unique per stream. I don't understand if this was intentional or not.
-}
newtype ConnectionCounter = ConnectionCounter Word32
    deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num)

data LocalEndPointState
    = LocalEndPointStateValid ValidLocalEndPointState
    | LocalEndPointStateClosed

data ValidLocalEndPointState = ValidLocalEndPointState
    { _localConnections :: Map (EndPointAddress, ConnectionCounter) RemoteEndPoint
    {- ^ We identify connections by remote endpoint address, AND ConnectionCounter,
    to support multiple connections between the same two endpoint addresses
    -}
    , _nextConnectionCounter :: ConnectionCounter
    }

data RemoteEndPoint = RemoteEndPoint
    { _remoteEndPointAddress :: !EndPointAddress
    , _remoteEndPointId :: !EndPointId
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
makeLenses ''ValidTransportState
makeLenses ''LocalEndPoint
makeLenses ''LocalEndPointState
makeLenses ''ValidLocalEndPointState
makeLenses ''RemoteEndPoint
makeLenses ''ValidRemoteEndPointState

-- | Fold over all open local endpoitns of a transport
foldOpenEndPoints :: QUICTransport -> (LocalEndPoint -> IO a) -> IO [a]
foldOpenEndPoints quicTransport f =
    readMVar (quicTransport ^. transportState) >>= \case
        TransportStateClosed -> pure []
        TransportStateValid st ->
            mapM f (Map.elems $ st ^. localEndPoints)

newLocalEndPoint :: QUICTransport -> TQueue Event -> IO (Either (TransportError NewEndPointErrorCode) LocalEndPoint)
newLocalEndPoint quicTransport newLocalQueue = do
    modifyMVar (quicTransport ^. transportState) $ \state -> case state of
        TransportStateClosed -> pure $ (TransportStateClosed, Left $ TransportError NewEndPointFailed "Transport closed")
        TransportStateValid validState -> do
            let newEndPointId = validState ^. nextEndPointId

            newLocalState <- newMVar (LocalEndPointStateValid $ ValidLocalEndPointState mempty 0)
            let openEndpoint =
                    OpenLocalEndPoint
                        { _localAddress =
                            encodeQUICAddr
                                ( QUICAddr
                                    (quicTransport ^. transportHost)
                                    (quicTransport ^. transportPort)
                                    newEndPointId
                                )
                        , _localEndPointId = newEndPointId
                        , _localEndPointState = newLocalState
                        , _localQueue = newLocalQueue
                        }

            pure
                ( TransportStateValid
                    ( validState
                        & localEndPoints %~ Map.insert newEndPointId openEndpoint
                        & nextEndPointId +~ 1
                    )
                , Right openEndpoint
                )

closeLocalEndpoint ::
    LocalEndPoint ->
    IO ()
closeLocalEndpoint localEndPoint = do
    atomically $ writeTQueue (localEndPoint ^. localQueue) EndPointClosed
    modifyMVar_ (localEndPoint ^. localEndPointState) $ \case
        LocalEndPointStateClosed -> pure LocalEndPointStateClosed
        LocalEndPointStateValid st ->
            mapM_ closeRemoteEndPoint (st ^. localConnections)
                $> LocalEndPointStateClosed

{- | Attempt to close a remote endpoint. If the remote endpoint is in
any non-valid state (e.g. already closed), then nothing happens.

Otherwise, a control message is sent to the remote end to nicely ask to
close this connection.
-}
closeRemoteEndPoint :: RemoteEndPoint -> IO ()
closeRemoteEndPoint remoteEndPoint = do
    mAct <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
        RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
        RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
        RemoteEndPointValid (ValidRemoteEndPointState stream isClosed) ->
            let cleanup = do
                    putStrLn $ "cleaning up id=" <> show (remoteEndPoint ^. remoteEndPointId)
                    sendCloseConnection stream (remoteEndPoint ^. remoteEndPointId)
                        >> putMVar isClosed ()
             in pure (RemoteEndPointClosed, Just cleanup)

    case mAct of
        Nothing -> pure ()
        Just act -> act

{- | Create a remote end point in the 'init' state.

The resulting remote end point is NOT set up, such that
it could be set up separately to /receive/ messages, or /send/ them.
-}
createRemoteEndPoint ::
    LocalEndPoint ->
    EndPointAddress ->
    IO (Either (TransportError ConnectErrorCode) (RemoteEndPoint, ConnectionCounter))
createRemoteEndPoint localEndPoint remoteAddress = do
    case decodeQUICAddr remoteAddress of
        Left errmsg -> throwIO (TransportError ConnectNotFound errmsg)
        Right (QUICAddr _ _ remoteId) -> do
            remoteEndPoint <- RemoteEndPoint remoteAddress remoteId <$> newMVar RemoteEndPointInit
            modifyMVar (localEndPoint ^. localEndPointState) $ \case
                LocalEndPointStateClosed -> pure $ (LocalEndPointStateClosed, Left $ TransportError ConnectFailed "endpoint is closed")
                LocalEndPointStateValid st ->
                    pure $
                        ( LocalEndPointStateValid $
                            st
                                & localConnections %~ Map.insert (remoteAddress, st ^. nextConnectionCounter) remoteEndPoint
                                & nextConnectionCounter +~ 1
                        , Right (remoteEndPoint, st ^. nextConnectionCounter)
                        )

{- | Create a remote end point, set up as a client that connects
to the remote 'EndPointAddress'.
-}
createConnectionTo ::
    NonEmpty Credential ->
    LocalEndPoint ->
    EndPointAddress ->
    IO (Either (TransportError ConnectErrorCode) RemoteEndPoint)
createConnectionTo creds localEndPoint remoteAddress = do
    createRemoteEndPoint localEndPoint remoteAddress >>= \case
        Left err -> pure $ Left err
        Right (remoteEndPoint, _) ->
            streamToEndpoint creds (localEndPoint ^. localAddress) remoteAddress >>= \case
                Left _ -> throwIO (userError "uh")
                Right (closeStream, stream) -> do
                    let validState =
                            RemoteEndPointValid $
                                ValidRemoteEndPointState
                                    { _remoteStream = stream
                                    , _remoteStreamIsClosed = closeStream
                                    }
                    modifyMVar_ (remoteEndPoint ^. remoteEndPointState) (\_ -> pure validState)
                    pure $ Right remoteEndPoint
