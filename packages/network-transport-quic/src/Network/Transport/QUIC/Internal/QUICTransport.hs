{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Network.Transport.QUIC.Internal.QUICTransport
  ( -- * QUICTransport
    QUICTransport,
    newQUICTransport,
    foldOpenEndPoints,
    transportConfig,
    transportInputSocket,
    transportState,

    -- ** Configuration
    QUICTransportConfig (..),
    defaultQUICTransportConfig,

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
    nextConnInId,
    nextSelfConnOutId,
    newLocalEndPoint,
    closeLocalEndpoint,

    -- * LocalEndPointState
    LocalEndPointState (..),
    ValidLocalEndPointState,
    incomingConnections,
    outgoingConnections,
    nextConnectionCounter,

    -- ** ConnectionCounter
    ConnectionCounter,

    -- * RemoteEndPoint
    RemoteEndPoint (..),
    remoteEndPointAddress,
    remoteEndPointId,
    remoteServerConnId,
    remoteEndPointState,
    closeRemoteEndPoint,
    createRemoteEndPoint,
    createConnectionTo,

    -- ** Remote endpoint state
    RemoteEndPointState (..),
    ValidRemoteEndPointState (..),
    remoteStream,
    remoteStreamIsClosed,
    remoteIncoming,
    remoteNextConnOutId,
    Direction (..),

    -- * Re-exports
    (^.),
  )
where

import Control.Concurrent.Async (forConcurrently_)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, putMVar, readMVar)
import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)
import Control.Exception (Exception (displayException), SomeException, bracketOnError, try)
import Control.Monad (forM_)
import Control.Monad.STM (atomically)
import Data.Binary qualified as Binary
import Data.ByteString qualified as BS
import Data.Function ((&))
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, (%~), (+~), (^.))
import Network.QUIC (Stream)
import Network.QUIC qualified as QUIC
import Network.Socket (HostName, ServiceName, Socket)
import Network.Socket qualified as N
import Network.TLS (Credential)
import Network.Transport (ConnectErrorCode (ConnectFailed), EndPointAddress, Event (EndPointClosed, ErrorEvent), EventErrorCode (EventConnectionLost), NewEndPointErrorCode (NewEndPointFailed), TransportError (TransportError))
import Network.Transport.QUIC.Internal.Client (streamToEndpoint)
import Network.Transport.QUIC.Internal.Messaging
  ( ClientConnId,
    ServerConnId,
    firstNonReservedServerConnId,
    sendCloseConnection,
    sendCloseEndPoint,
  )
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

-- | Represents the configuration used by the entire transport.
data QUICTransportConfig = QUICTransportConfig
  { -- | Host name, which can be an IP address or a domain name.
    hostName :: HostName,
    -- | Port or service name. The default is port 443.
    serviceName :: ServiceName,
    -- | At least one set of credentials is required.
    credentials :: NonEmpty Credential,
    -- | Note that if your credentials is self-signed, you will have
    -- to turn off 'validateCredentials'. This should only be set to 'False'
    -- in tests, or in a private network.
    validateCredentials :: Bool
  }
  deriving (Eq, Show)

defaultQUICTransportConfig :: HostName -> NonEmpty Credential -> QUICTransportConfig
defaultQUICTransportConfig host creds =
  QUICTransportConfig
    { hostName = host,
      serviceName = "443",
      credentials = creds,
      validateCredentials = True
    }

data QUICTransport = QUICTransport
  { _transportConfig :: QUICTransportConfig,
    _transportInputSocket :: Socket,
    _transportState :: MVar TransportState
  }

data TransportState
  = TransportStateValid ValidTransportState
  | TransportStateClosed

data ValidTransportState = ValidTransportState
  { _localEndPoints :: !(Map EndPointId LocalEndPoint),
    _nextEndPointId :: !EndPointId
  }

-- | Create a new QUICTransport
newQUICTransport :: QUICTransportConfig -> IO QUICTransport
newQUICTransport config = do
  addr <- NE.head <$> N.getAddrInfo (Just N.defaultHints) (Just (hostName config)) (Just (serviceName config))
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
        config{serviceName=show port}
        socket
        <$> newMVar (TransportStateValid $ ValidTransportState mempty 1)

data LocalEndPoint = OpenLocalEndPoint
  { _localAddress :: !EndPointAddress,
    _localEndPointId :: !EndPointId,
    _localEndPointState :: !(MVar LocalEndPointState),
    -- | Queue used to receive events
    _localQueue :: !(TQueue Event)
  }

-- | A 'ConnectionCounter' uniquely identifies a connections within the context of an endpoint.
-- This allows to hold multiple separate connections between two endpoint addresses.
--
-- NOTE: I tried to use the `StreamId` type from the `quic` library, but it was
-- clearly not unique per stream. I don't understand if this was intentional or not.
newtype ConnectionCounter = ConnectionCounter Word32
  deriving newtype (Eq, Show, Ord, Bounded, Enum, Real, Integral, Num)

data LocalEndPointState
  = LocalEndPointStateValid ValidLocalEndPointState
  | LocalEndPointStateClosed
  deriving (Show)

data ValidLocalEndPointState = ValidLocalEndPointState
  { _incomingConnections :: Map (EndPointAddress, ConnectionCounter) RemoteEndPoint,
    _outgoingConnections :: Map (EndPointAddress, ConnectionCounter) RemoteEndPoint,
    _nextSelfConnOutId :: !ClientConnId,
    -- | We identify connections by remote endpoint address, AND ConnectionCounter,
    --    to support multiple connections between the same two endpoint addresses
    _nextConnInId :: !ServerConnId,
    _nextConnectionCounter :: ConnectionCounter
  }
  deriving (Show)

data RemoteEndPoint = RemoteEndPoint
  { _remoteEndPointAddress :: !EndPointAddress,
    _remoteEndPointId :: !EndPointId,
    _remoteEndPointState :: !(MVar RemoteEndPointState)
  }

remoteServerConnId :: RemoteEndPoint -> ServerConnId
remoteServerConnId = fromIntegral . _remoteEndPointId

instance Show RemoteEndPoint where
  show (RemoteEndPoint address _ _) = "<RemoteEndPoint @ " <> show address <> ">"

data RemoteEndPointState
  = -- | In the short window between a connection
    --      being initiated and the handshake completing
    RemoteEndPointInit
  | RemoteEndPointValid ValidRemoteEndPointState
  | RemoteEndPointClosed

data ValidRemoteEndPointState = ValidRemoteEndPointState
  { _remoteStream :: Stream,
    _remoteStreamIsClosed :: MVar (),
    _remoteIncoming :: !(Maybe ClientConnId),
    _remoteNextConnOutId :: !ClientConnId
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
  modifyMVar (quicTransport ^. transportState) $ \case
    TransportStateClosed -> pure (TransportStateClosed, Left $ TransportError NewEndPointFailed "Transport closed")
    TransportStateValid validState -> do
      let newEndPointId = validState ^. nextEndPointId

      newLocalState <-
        newMVar
          ( LocalEndPointStateValid $
              ValidLocalEndPointState
                { _incomingConnections = mempty,
                  _outgoingConnections = mempty,
                  _nextConnInId = firstNonReservedServerConnId,
                  _nextSelfConnOutId = 0,
                  _nextConnectionCounter = 0
                }
          )
      let openEndpoint =
            OpenLocalEndPoint
              { _localAddress =
                  encodeQUICAddr
                    ( QUICAddr
                        (hostName $ quicTransport ^. transportConfig)
                        (serviceName $ quicTransport ^. transportConfig)
                        newEndPointId
                    ),
                _localEndPointId = newEndPointId,
                _localEndPointState = newLocalState,
                _localQueue = newLocalQueue
              }

      pure
        ( TransportStateValid
            ( validState
                & localEndPoints %~ Map.insert newEndPointId openEndpoint
                & nextEndPointId +~ 1
            ),
          Right openEndpoint
        )

closeLocalEndpoint ::
  QUICTransport ->
  LocalEndPoint ->
  IO ()
closeLocalEndpoint quicTransport localEndPoint = do
  modifyMVar_ (quicTransport ^. transportState) $ \case
    TransportStateClosed -> pure TransportStateClosed
    TransportStateValid vst ->
      pure . TransportStateValid $
        vst
          & localEndPoints
            %~ Map.delete (localEndPoint ^. localEndPointId)

  mPreviousState <- modifyMVar (localEndPoint ^. localEndPointState) $ \case
    LocalEndPointStateClosed -> pure (LocalEndPointStateClosed, Nothing)
    LocalEndPointStateValid st -> pure (LocalEndPointStateClosed, Just st)

  forM_ mPreviousState $ \vst ->
    forConcurrently_
      (vst ^. incomingConnections <> vst ^. outgoingConnections)
      tryCloseRemoteStream
  atomically $ writeTQueue (localEndPoint ^. localQueue) EndPointClosed
  where
    tryCloseRemoteStream :: RemoteEndPoint -> IO ()
    tryCloseRemoteStream remoteEndPoint = do
      mCleanup <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
        RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
        RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
        RemoteEndPointValid vst ->
          pure
            ( RemoteEndPointClosed,
              Just $ do
                sendCloseEndPoint (vst ^. remoteStream)
                  >> putMVar (vst ^. remoteStreamIsClosed) ()
            )

      case mCleanup of
        Nothing -> pure ()
        Just cleanup -> cleanup

-- | Attempt to close a remote endpoint. If the remote endpoint is in
-- any non-valid state (e.g. already closed), then nothing happens.
--
-- Otherwise, a control message is sent to the remote end to nicely ask to
-- close this connection.
closeRemoteEndPoint :: Direction -> RemoteEndPoint -> IO ()
closeRemoteEndPoint direction remoteEndPoint = do
  mAct <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
    RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
    RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
    RemoteEndPointValid (ValidRemoteEndPointState stream isClosed conns _) ->
      let cleanup =
            case direction of
              Outgoing -> Right <$> forM_ conns (`sendCloseConnection` stream)
              Incoming -> sendCloseEndPoint stream
              >> putMVar isClosed ()
       in pure (RemoteEndPointClosed, Just cleanup)

  case mAct of
    Nothing -> pure ()
    Just act -> act

data Direction
  = Outgoing
  | Incoming
  deriving (Eq, Show, Ord, Enum, Bounded)

-- | Create a remote end point in the 'init' state.
--
-- The resulting remote end point is NOT set up, such that
-- it could be set up separately to /receive/ messages, or /send/ them.
createRemoteEndPoint ::
  LocalEndPoint ->
  EndPointAddress ->
  Direction ->
  IO (Either (TransportError ConnectErrorCode) (RemoteEndPoint, ConnectionCounter))
createRemoteEndPoint localEndPoint remoteAddress direction = do
  modifyMVar (localEndPoint ^. localEndPointState) $ \case
    LocalEndPointStateClosed -> pure (LocalEndPointStateClosed, Left $ TransportError ConnectFailed "endpoint is closed")
    LocalEndPointStateValid st -> do
      remoteEndPoint <-
        RemoteEndPoint
          remoteAddress
          -- The design of using the next Server connection ID
          -- as the RemoteId comes from the TCP transport

          (fromIntegral $ st ^. nextConnInId)
          <$> newMVar RemoteEndPointInit
      pure
        ( LocalEndPointStateValid $
            st
              & (if direction == Incoming then incomingConnections else outgoingConnections) %~ Map.insert (remoteAddress, st ^. nextConnectionCounter) remoteEndPoint
              & nextConnectionCounter +~ 1
              & nextConnInId +~ 1,
          Right (remoteEndPoint, st ^. nextConnectionCounter)
        )

-- | Create a remote end point, set up as a client that connects
-- to the remote 'EndPointAddress'.
createConnectionTo ::
  NonEmpty Credential ->
  -- | Validate credentials
  Bool ->
  LocalEndPoint ->
  EndPointAddress ->
  IO (Either (TransportError ConnectErrorCode) (RemoteEndPoint, ClientConnId))
createConnectionTo creds validateCreds localEndPoint remoteAddress = do
  createRemoteEndPoint localEndPoint remoteAddress Outgoing >>= \case
    Left err -> pure $ Left err
    Right (remoteEndPoint, _) ->
      streamToEndpoint
        creds
        validateCreds
        (localEndPoint ^. localAddress)
        remoteAddress
        (\_ -> closeRemoteEndPoint Outgoing remoteEndPoint)
        onConnectionLost
        >>= \case
          Left exc -> pure $ Left exc
          Right (closeStream, stream) -> do
            let clientConnId = 0
                validState =
                  RemoteEndPointValid $
                    ValidRemoteEndPointState
                      { _remoteStream = stream,
                        _remoteStreamIsClosed = closeStream,
                        _remoteIncoming = Nothing,
                        _remoteNextConnOutId = clientConnId + 1
                      }
            modifyMVar_
              (remoteEndPoint ^. remoteEndPointState)
              (\_ -> pure validState)

            try
              ( QUIC.sendStream
                  stream
                  ( BS.toStrict $
                      Binary.encode clientConnId
                  )
              )
              >>= \case
                Left (exc :: SomeException) -> pure . Left $ TransportError ConnectFailed (displayException exc)
                Right () -> pure $ Right (remoteEndPoint, clientConnId)
  where
    onConnectionLost =
      atomically
        . writeTQueue (localEndPoint ^. localQueue)
        . ErrorEvent
        $ TransportError
          (EventConnectionLost remoteAddress)
          "Connection reset"
