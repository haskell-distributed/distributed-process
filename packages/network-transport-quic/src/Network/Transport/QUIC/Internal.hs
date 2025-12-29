{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal
  ( createTransport,
    QUICTransportConfig (..),
    defaultQUICTransportConfig,
    QUICAddr (..),
    encodeQUICAddr,
    decodeQUICAddr,

    -- * Re-export to generate credentials
    Credential,
    credentialLoadX509,

    -- * Message encoding and decoding
    decodeMessage,
    MessageReceived (..),
    encodeMessage,
  )
where

import Control.Concurrent (forkIO, killThread, modifyMVar_, newEmptyMVar, readMVar)
import Control.Concurrent.MVar (modifyMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.STM (atomically, newTQueueIO)
import Control.Concurrent.STM.TQueue
  ( TQueue,
    readTQueue,
    writeTQueue,
  )
import Control.Exception (Exception (displayException), IOException, bracket, throwIO, try)
import Control.Monad (unless, when)
import Data.Bifunctor (Bifunctor (first))
import Data.Binary qualified as Binary (decodeOrFail)
import Data.ByteString (ByteString, fromStrict)
import Data.Foldable (forM_)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Lens.Micro.Platform ((+~))
import Network.QUIC qualified as QUIC
import Network.TLS (Credential)
import Network.Transport
  ( ConnectErrorCode (ConnectFailed),
    ConnectHints,
    Connection (..),
    EndPoint (..),
    EndPointAddress,
    Event (..),
    EventErrorCode (EventConnectionLost),
    NewEndPointErrorCode,
    NewMulticastGroupErrorCode (NewMulticastGroupUnsupported),
    Reliability (ReliableOrdered),
    ResolveMulticastGroupErrorCode (ResolveMulticastGroupUnsupported),
    SendErrorCode (SendClosed, SendFailed),
    Transport (..),
    TransportError (..),
  )
import Network.Transport.QUIC.Internal.Configuration (credentialLoadX509)
import Network.Transport.QUIC.Internal.Messaging
  ( ClientConnId,
    MessageReceived (..),
    createConnectionId,
    decodeMessage,
    encodeMessage,
    receiveMessage,
    recvWord32,
    sendAck,
    sendCloseConnection,
    sendMessage,
    sendRejection,
    serverSelfConnId,
  )
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (..), decodeQUICAddr, encodeQUICAddr)
import Network.Transport.QUIC.Internal.QUICTransport
  ( Direction (..),
    LocalEndPoint,
    LocalEndPointState (LocalEndPointStateClosed, LocalEndPointStateValid),
    QUICTransport,
    QUICTransportConfig (..),
    RemoteEndPoint (..),
    RemoteEndPointState (..),
    TransportState (..),
    ValidRemoteEndPointState (..),
    closeLocalEndpoint,
    closeRemoteEndPoint,
    createConnectionTo,
    createRemoteEndPoint,
    defaultQUICTransportConfig,
    foldOpenEndPoints,
    localAddress,
    localEndPointState,
    localEndPoints,
    localQueue,
    newLocalEndPoint,
    newQUICTransport,
    nextSelfConnOutId,
    remoteEndPointAddress,
    remoteEndPointState,
    remoteIncoming,
    remoteServerConnId,
    remoteStream,
    transportConfig,
    transportInputSocket,
    transportState,
    (^.),
  )
import Network.Transport.QUIC.Internal.Server (forkServer)

-- | Create a new Transport based on the QUIC protocol.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport ::
  QUICTransportConfig ->
  IO Transport
createTransport initialConfig = do
  quicTransport <- newQUICTransport initialConfig

  let resolvedConfig = quicTransport ^. transportConfig
  serverThread <-
    forkServer
      (quicTransport ^. transportInputSocket)
      (credentials resolvedConfig)
      throwIO
      throwIO
      (handleNewStream quicTransport)

  pure $
    Transport
      { newEndPoint = newTQueueIO >>= newEndpoint quicTransport,
        closeTransport =
          foldOpenEndPoints quicTransport (closeLocalEndpoint quicTransport)
            >> killThread serverThread -- TODO: use a synchronization mechanism to close the thread gracefully
            >> modifyMVar_
              (quicTransport ^. transportState)
              (\_ -> pure TransportStateClosed)
      }

-- | Handle a new incoming connection.
--
-- This is the function which:
-- 1. First initiates a relationship between endpoints, called a /handshake/
-- 2. then continuously reads from the stream to queue up events for the appropriate endpoint.
handleNewStream :: QUICTransport -> QUIC.Stream -> IO ()
handleNewStream quicTransport stream = do
  unless
    ( QUIC.isClientInitiatedBidirectional
        (QUIC.streamId stream)
    )
    (throwIO (userError "QUIC stream is not bidirectional"))

  -- HANDSHAKE
  -- At this time, the handshake is very simple:
  -- we read the first message, which must be addressed
  -- correctly by EndPointId. This first message is expected
  -- to contain the other side's EndPointAddress
  --
  -- If the EndPointId does not exist, we terminate the connection.
  recvWord32 stream
    >>= either (throwIO . userError) (pure . fromIntegral)
    >>= QUIC.recvStream stream
    >>= \payload -> do
      case Binary.decodeOrFail (fromStrict payload) of
        Left (_, _, errmsg) ->
          throwIO (userError $ "(handleNewStream) remote endpoint address in handshake could not be decoded: " <> errmsg)
        Right (_, _, (remoteAddress, endpointId)) ->
          readMVar (quicTransport ^. transportState) >>= \case
            TransportStateClosed -> throwIO $ userError "Transport closed"
            TransportStateValid state -> case Map.lookup endpointId (state ^. localEndPoints) of
              Nothing -> sendRejection stream
              Just ourEndPoint -> do
                readMVar (ourEndPoint ^. localEndPointState) >>= \case
                  LocalEndPointStateClosed -> sendRejection stream
                  LocalEndPointStateValid _ -> do
                    sendAck stream

                    (remoteEndPoint, _) <- either throwIO pure =<< createRemoteEndPoint ourEndPoint remoteAddress Incoming
                    doneMVar <- newEmptyMVar

                    -- Sending an ack is important, because otherwise
                    -- the client may start sending messages well before we
                    -- start being able to receive them

                    clientConnId <- either (throwIO . userError) (pure . fromIntegral) =<< recvWord32 stream
                    let serverConnId = remoteServerConnId remoteEndPoint
                        connectionId = createConnectionId serverConnId clientConnId

                    let st =
                          RemoteEndPointValid $
                            ValidRemoteEndPointState
                              { _remoteStream = stream,
                                _remoteStreamIsClosed = doneMVar,
                                _remoteIncoming = Just clientConnId,
                                _remoteNextConnOutId = 0
                              }
                    modifyMVar_
                      (remoteEndPoint ^. remoteEndPointState)
                      ( \case
                          RemoteEndPointInit -> pure st
                          _ -> undefined
                      )

                    tid <-
                      forkIO $
                        -- If we've reached this stage, the connection handhake succeeded
                        handleIncomingMessages
                          ourEndPoint
                          remoteEndPoint

                    atomically $
                      writeTQueue
                        (ourEndPoint ^. localQueue)
                        ( ConnectionOpened
                            connectionId
                            ReliableOrdered
                            remoteAddress
                        )

                    takeMVar doneMVar
                    QUIC.shutdownStream stream
                    killThread tid

-- | Infinite loop that listens for messages from the remote endpoint and processes them.
--
-- This function assumes that the handshake has been completed.
handleIncomingMessages :: LocalEndPoint -> RemoteEndPoint -> IO ()
handleIncomingMessages ourEndPoint remoteEndPoint =
  bracket acquire release go
  where
    serverConnId = remoteServerConnId remoteEndPoint
    ourQueue = ourEndPoint ^. localQueue
    remoteAddress = remoteEndPoint ^. remoteEndPointAddress
    remoteState = remoteEndPoint ^. remoteEndPointState

    acquire :: IO (Either IOError QUIC.Stream)
    acquire = withMVar remoteState $ \case
      RemoteEndPointInit -> pure . Left $ userError "handleIncomingMessages (init)"
      RemoteEndPointClosed -> pure . Left $ userError "handleIncomingMessages (closed)"
      RemoteEndPointValid validState -> pure . Right $ validState ^. remoteStream

    release :: Either IOError QUIC.Stream -> IO ()
    release (Left err) = closeRemoteEndPoint Incoming remoteEndPoint >> prematureExit err
    release (Right _) = closeRemoteEndPoint Incoming remoteEndPoint

    connectionId = createConnectionId serverConnId

    writeConnectionClosedSTM connId =
      writeTQueue
        ourQueue
        (ConnectionClosed (connectionId connId))

    go = either prematureExit loop

    loop stream =
      receiveMessage stream
        >>= \case
          Left errmsg -> do
            -- Throwing will trigger 'prematureExit'
            throwIO $ userError $ "(handleIncomingMessages) Failed with: " <> errmsg
          Right (Message connId bytes) -> handleMessage connId bytes >> loop stream
          Right StreamClosed -> throwIO $ userError "(handleIncomingMessages) Stream closed"
          Right (CloseConnection connId) -> do
            atomically (writeConnectionClosedSTM connId)
            mAct <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
              RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
              RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
              RemoteEndPointValid (ValidRemoteEndPointState _ isClosed _ _) -> do
                pure (RemoteEndPointClosed, Just $ putMVar isClosed ())
            case mAct of
              Nothing -> pure ()
              Just cleanup -> cleanup
          Right CloseEndPoint -> do
            connIds <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
              RemoteEndPointValid vst -> do
                pure (RemoteEndPointClosed, vst ^. remoteIncoming)
              other -> pure (other, Nothing)
            unless
              (isNothing connIds)
              ( atomically $
                  forM_
                    connIds
                    (writeTQueue ourQueue . ConnectionClosed . connectionId)
              )

    handleMessage :: ClientConnId -> [ByteString] -> IO ()
    handleMessage clientConnId payload =
      atomically (writeTQueue ourQueue (Received (connectionId clientConnId) payload))

    prematureExit :: IOException -> IO ()
    prematureExit exc = do
      modifyMVar_ remoteState $ \case
        RemoteEndPointValid {} -> pure RemoteEndPointClosed
        RemoteEndPointInit -> pure RemoteEndPointClosed
        RemoteEndPointClosed -> pure RemoteEndPointClosed
      atomically
        ( writeTQueue
            ourQueue
            ( ErrorEvent
                ( TransportError
                    (EventConnectionLost remoteAddress)
                    (displayException exc)
                )
            )
        )

newEndpoint ::
  QUICTransport ->
  TQueue Event ->
  IO (Either (TransportError NewEndPointErrorCode) EndPoint)
newEndpoint quicTransport newLocalQueue = do
  newLocalEndPoint quicTransport newLocalQueue >>= \case
    Left err -> pure $ Left err
    Right ourEndPoint ->
      try $
        pure $
          EndPoint
            { receive = atomically (readTQueue (ourEndPoint ^. localQueue)),
              address = ourEndPoint ^. localAddress,
              connect =
                newConnection
                  ourEndPoint
                  (credentials $ quicTransport ^. transportConfig)
                  (validateCredentials $ quicTransport ^. transportConfig),
              newMulticastGroup =
                pure . Left $
                  TransportError
                    NewMulticastGroupUnsupported
                    "Multicast not supported",
              resolveMulticastGroup =
                pure
                  . Left
                  . const
                    ( TransportError
                        ResolveMulticastGroupUnsupported
                        "Multicast not supported"
                    ),
              closeEndPoint = closeLocalEndpoint quicTransport ourEndPoint
            }

newConnection ::
  LocalEndPoint ->
  NonEmpty Credential ->
  -- | Validate credentials
  Bool ->
  EndPointAddress ->
  Reliability ->
  ConnectHints ->
  IO (Either (TransportError ConnectErrorCode) Connection)
newConnection ourEndPoint creds validateCreds remoteAddress _reliability _connectHints =
  if ourAddress == remoteAddress
    then connectToSelf ourEndPoint
    else
      createConnectionTo creds validateCreds ourEndPoint remoteAddress >>= \case
        Left err -> pure $ Left err
        Right (remoteEndPoint, connId) -> do
          connAlive <- newIORef True
          pure
            . Right
            $ Connection
              { send = sendConn remoteEndPoint connAlive connId,
                close = closeConn remoteEndPoint connAlive connId
              }
  where
    ourAddress = ourEndPoint ^. localAddress
    sendConn remoteEndPoint connAlive connId packets =
      readMVar (remoteEndPoint ^. remoteEndPointState) >>= \case
        RemoteEndPointInit -> undefined
        RemoteEndPointValid vst ->
          readIORef connAlive >>= \case
            False -> pure . Left $ TransportError SendClosed "Connection closed"
            True ->
              sendMessage (vst ^. remoteStream) connId packets
                <&> first (TransportError SendFailed . show)
        RemoteEndPointClosed -> do
          readIORef connAlive >>= \case
            -- This is normal. If the remote endpoint closes up while we have
            -- an outgoing connection (CloseEndPoint or CloseSocket message),
            -- we'll post the connection lost event but we won't update these
            -- 'connAlive' IORefs.
            False -> pure . Left $ TransportError SendClosed "Connection closed"
            True -> pure . Left $ TransportError SendFailed "Remote endpoint closed"
    closeConn remoteEndPoint connAlive connId = do
      mCleanup <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
        RemoteEndPointValid vst@(ValidRemoteEndPointState stream isClosed _ _) -> do
          readIORef connAlive >>= \case
            False -> pure (RemoteEndPointValid vst, Nothing)
            True -> do
              writeIORef connAlive False
              -- We want to run this cleanup action OUTSIDE of the MVar modification
              let cleanup = sendCloseConnection connId stream
              pure (RemoteEndPointClosed, Just $ cleanup >> putMVar isClosed ())
        _ -> pure (RemoteEndPointClosed, Nothing)

      case mCleanup of
        Nothing -> pure ()
        Just cleanup -> cleanup

connectToSelf ::
  LocalEndPoint ->
  IO (Either (TransportError ConnectErrorCode) Connection)
connectToSelf ourEndPoint = do
  connAlive <- newIORef True
  modifyMVar
    (ourEndPoint ^. localEndPointState)
    ( \case
        LocalEndPointStateClosed ->
          pure
            ( LocalEndPointStateClosed,
              Left $ TransportError ConnectFailed "Local endpoint closed"
            )
        LocalEndPointStateValid vst ->
          pure
            ( LocalEndPointStateValid $ vst & nextSelfConnOutId +~ 1,
              Right $ vst ^. nextSelfConnOutId
            )
    )
    >>= \case
      Left err -> pure $ Left err
      Right clientConnId -> do
        let connId = createConnectionId serverSelfConnId clientConnId
        atomically $
          writeTQueue
            queue
            ( ConnectionOpened
                connId
                ReliableOrdered
                (ourEndPoint ^. localAddress)
            )
        pure . Right $
          Connection
            { send = selfSend connAlive connId,
              close = selfClose connAlive connId
            }
  where
    queue = ourEndPoint ^. localQueue
    selfSend connAlive connId msg =
      try . withMVar (ourEndPoint ^. localEndPointState) $ \case
        LocalEndPointStateValid _ -> do
          alive <- readIORef connAlive
          if alive
            then
              seq
                (foldr seq () msg)
                ( atomically $
                    writeTQueue
                      queue
                      (Received connId msg)
                )
            else throwIO $ TransportError SendClosed "Connection closed"
        LocalEndPointStateClosed ->
          throwIO $ TransportError SendFailed "Endpoint closed"

    selfClose connAlive connId =
      withMVar (ourEndPoint ^. localEndPointState) $ \case
        LocalEndPointStateValid _ -> do
          alive <- readIORef connAlive
          when alive $ do
            atomically $ writeTQueue queue (ConnectionClosed connId)
            writeIORef connAlive False
        LocalEndPointStateClosed ->
          return ()
