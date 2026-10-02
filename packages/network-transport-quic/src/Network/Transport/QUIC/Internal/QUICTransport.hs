{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TupleSections #-}

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
    outgoingPeers,
    nextConnectionCounter,

    -- ** OutgoingPeer
    OutgoingPeer,

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
    remoteStreamDrained,
    Direction (..),

    -- * Re-exports
    (^.),
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM.TQueue (TQueue, writeTQueue)
import Control.Exception (bracketOnError, onException)
import Control.Monad (filterM, forM_, unless, void, when)
import Control.Monad.STM (atomically)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Word (Word32)
import Lens.Micro.Platform (makeLenses, (%~), (+~), (^.))
import Network.QUIC (Stream)
import Network.Socket (HostName, ServiceName, Socket)
import Network.Socket qualified as N
import Network.TLS (Credential)
import Network.Transport (ConnectErrorCode (ConnectFailed), EndPointAddress, Event (EndPointClosed, ErrorEvent), EventErrorCode (EventConnectionLost), NewEndPointErrorCode (NewEndPointFailed), TransportError (TransportError))
import Network.Transport.QUIC.Internal.Client
  ( PeerConnection (..),
    closeTimeout,
    connectToPeer,
    openStream,
    superviseStream,
  )
import Network.Transport.QUIC.Internal.Messaging
  ( ClientConnId,
    ServerConnId,
    firstNonReservedServerConnId,
    sendCloseConnection,
    sendCloseEndPoint,
  )
import Network.Transport.QUIC.Internal.QUICAddr (EndPointId, QUICAddr (..), encodeQUICAddr)
import System.Timeout (timeout)

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
    _outgoingPeers :: Map EndPointAddress OutgoingPeer,
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
  = -- | In the short window between a connection being initiated and the handshake completing
    RemoteEndPointInit
  | RemoteEndPointValid ValidRemoteEndPointState
  | RemoteEndPointClosed

data ValidRemoteEndPointState = ValidRemoteEndPointState
  { _remoteStream :: Stream,
    _remoteStreamIsClosed :: MVar (),
    _remoteStreamDrained :: MVar ()
  }

data OutgoingPeer = OutgoingPeer
  { _peerConnection :: !(MVar (Either (TransportError ConnectErrorCode) PeerConnection)),
    _peerLostReported :: !(IORef Bool),
    _peerStreams :: !(MVar (Maybe (Map EndPointId (RemoteEndPoint, MVar ()))))
  }

instance Show OutgoingPeer where
  show _ = "<OutgoingPeer>"

makeLenses ''QUICTransport
makeLenses ''OutgoingPeer
makeLenses ''TransportState
makeLenses ''ValidTransportState
makeLenses ''LocalEndPoint
makeLenses ''LocalEndPointState
makeLenses ''ValidLocalEndPointState
makeLenses ''RemoteEndPoint
makeLenses ''ValidRemoteEndPointState

dropPeer :: LocalEndPoint -> EndPointAddress -> OutgoingPeer -> IO ()
dropPeer localEndPoint remoteAddress peer =
  modifyMVar_ (localEndPoint ^. localEndPointState) $ \case
    LocalEndPointStateClosed -> pure LocalEndPointStateClosed
    LocalEndPointStateValid st ->
      pure . LocalEndPointStateValid $
        st & outgoingPeers %~ Map.update (\current -> if sameAs current then Nothing else Just current) remoteAddress
  where
    sameAs current = (current ^. peerConnection) == (peer ^. peerConnection)

registerStream :: OutgoingPeer -> RemoteEndPoint -> MVar () -> IO Bool
registerStream peer remoteEndPoint drained =
  modifyMVar (peer ^. peerStreams) $ \case
    Nothing -> pure (Nothing, False)
    Just current -> pure (Just (Map.insert (remoteEndPoint ^. remoteEndPointId) (remoteEndPoint, drained) current), True)

unregisterStream :: OutgoingPeer -> RemoteEndPoint -> IO ()
unregisterStream peer remoteEndPoint =
  modifyMVar_ (peer ^. peerStreams) (pure . fmap (Map.delete (remoteEndPoint ^. remoteEndPointId)))

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
                  _outgoingPeers = mempty,
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

  -- Close outgoing remote endpoints before incoming
  forM_ mPreviousState $ \vst -> do
    outgoingDrained <- catMaybes <$> forConcurrently (Map.elems $ vst ^. outgoingConnections) tryCloseRemoteStream
    _ <- timeout closeTimeout (mapM_ readMVar outgoingDrained)
    _ <- forConcurrently (Map.elems $ vst ^. incomingConnections) tryCloseRemoteStream
    -- Everything we had to say on these QUIC connections has been said.
    forM_ (vst ^. outgoingPeers) shutdownPeer
  atomically $ writeTQueue (localEndPoint ^. localQueue) EndPointClosed
  where
    -- Returns the MVar which is filled once the stream is closed, if we had to close it.
    tryCloseRemoteStream :: RemoteEndPoint -> IO (Maybe (MVar ()))
    tryCloseRemoteStream remoteEndPoint = do
      mCleanup <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
        RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
        RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
        RemoteEndPointValid vst ->
          pure
            ( RemoteEndPointClosed,
              Just $ do
                _ <- sendCloseEndPoint (vst ^. remoteStream)
                _ <- tryPutMVar (vst ^. remoteStreamIsClosed) ()
                pure (vst ^. remoteStreamDrained)
            )

      sequence mCleanup

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
    RemoteEndPointValid (ValidRemoteEndPointState stream isClosed _) ->
      let cleanup = do
            _ <- case direction of
              Outgoing -> sendCloseConnection stream
              Incoming -> sendCloseEndPoint stream
            _ <- tryPutMVar isClosed ()
            pure ()
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
  IO (Either (TransportError ConnectErrorCode) RemoteEndPoint)
createConnectionTo creds validateCreds localEndPoint remoteAddress = do
  createRemoteEndPoint localEndPoint remoteAddress Outgoing >>= \case
    Left err -> pure $ Left err
    Right (remoteEndPoint, _) -> do
      let abandon :: TransportError ConnectErrorCode -> IO (Either (TransportError ConnectErrorCode) a)
          abandon err = do
            modifyMVar_ (remoteEndPoint ^. remoteEndPointState) (\_ -> pure RemoteEndPointClosed)
            pure $ Left err

      acquirePeer creds validateCreds localEndPoint remoteAddress >>= \case
        Left err -> abandon err
        Right (peer, peerConn) -> do
          awaitPendingCloses peer
          openStream peerConn (localEndPoint ^. localAddress) remoteAddress >>= \case
            Left err -> abandon err
            Right stream -> do
              closeRequested <- newEmptyMVar
              drained <- newEmptyMVar
              -- The remote endpoint must be Valid before anything can observe the
              -- stream ending, or a loss would be missed.
              modifyMVar_
                (remoteEndPoint ^. remoteEndPointState)
                (\_ -> pure . RemoteEndPointValid $ ValidRemoteEndPointState stream closeRequested drained)

              registerStream peer remoteEndPoint drained >>= \case
                False -> do
                  -- The peer was lost while we were connecting
                  _ <- tryPutMVar closeRequested ()
                  abandon (TransportError ConnectFailed "Connection lost")
                True -> do
                  superviseStream
                    stream
                    closeRequested
                    drained
                    (surfaceConnectionLost localEndPoint remoteAddress peer remoteEndPoint)
                    (unregisterStream peer remoteEndPoint)
                  pure $ Right remoteEndPoint
  where
    awaitPendingCloses peer = do
      streams <- maybe [] Map.elems <$> readMVar (peer ^. peerStreams)
      closing <- flip filterM streams $ \(remoteEndPoint, _) ->
        readMVar (remoteEndPoint ^. remoteEndPointState) <&> \case
          RemoteEndPointValid _ -> False
          _ -> True
      unless (null closing) $
        () <$ timeout closeTimeout (forM_ closing (readMVar . snd))

acquirePeer ::
  NonEmpty Credential ->
  -- | Validate credentials
  Bool ->
  LocalEndPoint ->
  EndPointAddress ->
  IO (Either (TransportError ConnectErrorCode) (OutgoingPeer, PeerConnection))
acquirePeer creds validateCreds localEndPoint remoteAddress = do
  candidate <- OutgoingPeer <$> newEmptyMVar <*> newIORef False <*> newMVar (Just mempty)

  claim <- modifyMVar (localEndPoint ^. localEndPointState) $ \case
    LocalEndPointStateClosed ->
      pure (LocalEndPointStateClosed, Left $ TransportError ConnectFailed "endpoint is closed")
    LocalEndPointStateValid st -> case Map.lookup remoteAddress (st ^. outgoingPeers) of
      Just peer -> pure (LocalEndPointStateValid st, Right (peer, False))
      Nothing ->
        pure
          ( LocalEndPointStateValid (st & outgoingPeers %~ Map.insert remoteAddress candidate),
            Right (candidate, True)
          )

  case claim of
    Left err -> pure $ Left err
    Right (peer, weMustConnect) -> do
      when weMustConnect $ do
        result <-
          connectToPeer creds validateCreds remoteAddress (onPeerLost peer)
            `onException` do
              _ <- tryPutMVar (peer ^. peerConnection) (Left $ TransportError ConnectFailed "interrupted")
              dropPeer localEndPoint remoteAddress peer
        _ <- tryPutMVar (peer ^. peerConnection) result
        
        either (const $ dropPeer localEndPoint remoteAddress peer) (const $ pure ()) result

        stillOpen <-
          readMVar (localEndPoint ^. localEndPointState) <&> \case
            LocalEndPointStateValid _ -> True
            LocalEndPointStateClosed -> False
        unless stillOpen (shutdownPeer peer)

      fmap (peer,) <$> readMVar (peer ^. peerConnection)
  where
    onPeerLost peer = do
      dropPeer localEndPoint remoteAddress peer
      streams <- modifyMVar (peer ^. peerStreams) (\current -> pure (Nothing, maybe [] (fmap fst . Map.elems) current))
      forM_ streams (surfaceConnectionLost localEndPoint remoteAddress peer)



-- | Idempotent: surfaces EventConnectionLost exactly once per peer, only if the remote
-- endpoint was still Valid when invoked. Called from multiple termination
-- sites (peer-initiated close, QUIC exception, loss of the QUIC connection) so that
-- no close path can leave us silent — the state-transition gate dedupes them.
surfaceConnectionLost :: LocalEndPoint -> EndPointAddress -> OutgoingPeer -> RemoteEndPoint -> IO ()
surfaceConnectionLost localEndPoint remoteAddress peer remoteEndPoint = do
  mAct <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
    RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
    RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
    RemoteEndPointValid (ValidRemoteEndPointState stream isClosed _) ->
      let cleanup = do
            _ <- sendCloseConnection stream
            _ <- tryPutMVar isClosed ()
            reportPeerLost
       in pure (RemoteEndPointClosed, Just cleanup)
  sequence_ mAct
  where
    reportPeerLost = do
      firstReport <- atomicModifyIORef' (peer ^. peerLostReported) (\reported -> (True, not reported))
      when firstReport $ do
        dropPeer localEndPoint remoteAddress peer
        atomically
          . writeTQueue (localEndPoint ^. localQueue)
          . ErrorEvent
          $ TransportError
            (EventConnectionLost remoteAddress)
            "Connection reset"

        shutdownPeerWhenDrained

    shutdownPeerWhenDrained =
      void . forkIO $ do
        streams <- maybe [] Map.elems <$> readMVar (peer ^. peerStreams)
        _ <- timeout closeTimeout (forM_ streams (readMVar . snd))
        shutdownPeer peer
  
-- | Close the QUIC connection to a peer. Streams on it must have been dealt with beforehand.
shutdownPeer :: OutgoingPeer -> IO ()
shutdownPeer peer =
  tryReadMVar (peer ^. peerConnection) >>= \case
    Just (Right peerConn) -> () <$ tryPutMVar (peerShutdown peerConn) ()
    _ -> pure ()