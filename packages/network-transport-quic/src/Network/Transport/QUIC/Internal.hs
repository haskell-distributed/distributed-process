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

    -- * Handshake
    handshake,
  )
where

import Control.Concurrent (forkIO, killThread, modifyMVar_, newEmptyMVar, readMVar)
import Control.Concurrent.MVar (modifyMVar, putMVar, takeMVar, tryPutMVar, withMVar)
import Control.Concurrent.STM (atomically, newTQueueIO)
import Control.Concurrent.STM.TQueue
  ( TQueue,
    readTQueue,
    writeTQueue,
  )
import Control.Exception (Exception (displayException, fromException), SomeAsyncException, SomeException, bracket, catch, finally, throwIO, try)
import Control.Monad (unless, when)
import Data.Bifunctor (Bifunctor (first))
import Data.Binary qualified as Binary (decodeOrFail)
import Data.ByteString (ByteString, fromStrict)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
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
  ( MessageReceived (..),
    createConnectionId,
    decodeMessage,
    encodeMessage,
    handshake,
    messageReceiver,
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
    closeLocalEndpointDeferred,
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
    remoteServerConnId,
    remoteStream,
    transportConfig,
    transportInputSocket,
    transportState,
    (^.),
  )
import Network.Transport.QUIC.Internal.Server (forkServer, stopServer)

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
  server <-
    forkServer
      (quicTransport ^. transportInputSocket)
      (credentials resolvedConfig)
      throwIO
      throwIO
      (handleNewStream quicTransport)

  pure $
    Transport
      { newEndPoint = newTQueueIO >>= newEndpoint quicTransport,
        closeTransport = do
          shutdownPeers <- foldOpenEndPoints quicTransport (closeLocalEndpointDeferred quicTransport)
          stopServer server `finally` sequence_ shutdownPeers
          modifyMVar_
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
                    drained <- newEmptyMVar

                    let serverConnId = remoteServerConnId remoteEndPoint
                        -- One logical connection per stream; clientConnId is always 0.
                        connectionId = createConnectionId serverConnId 0

                    let st =
                          RemoteEndPointValid $
                            ValidRemoteEndPointState
                              { _remoteStream = stream,
                                _remoteStreamIsClosed = doneMVar,
                                _remoteStreamDrained = drained
                              }
                    modifyMVar_
                      (remoteEndPoint ^. remoteEndPointState)
                      ( \case
                          RemoteEndPointInit -> pure st
                          _ -> undefined
                      )

                    -- Enqueue ConnectionOpened before forking the reader thread.
                    -- Otherwise the reader may dequeue a Message off the stream and
                    -- enqueue Received/ConnectionClosed before ConnectionOpened, which
                    -- breaks the ordering guarantee the transport API owes callers.
                    atomically $
                      writeTQueue
                        (ourEndPoint ^. localQueue)
                        ( ConnectionOpened
                            connectionId
                            ReliableOrdered
                            remoteAddress
                        )

                    -- Second handshake ack: only sent after ConnectionOpened is
                    -- enqueued. The initiator's @connect@ call blocks on this ack, so
                    -- when it returns, the caller can trust that any peer observing
                    -- events on this endpoint will see ConnectionOpened before any
                    -- messages the caller subsequently sends on other connections.
                    sendAck stream

                    tid <-
                      forkIO $
                        handleIncomingMessages
                          ourEndPoint
                          remoteEndPoint
                          `finally` tryPutMVar doneMVar ()

                    -- Once 'ConnectionClosed' (or the like) was enqueued, finishing our
                    -- end of the stream tells the other end that it was.
                    ( takeMVar doneMVar
                        >> (QUIC.shutdownStream stream `catch` \(_ :: SomeException) -> pure ())
                        >> killThread tid
                      )
                      `finally` tryPutMVar drained ()

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

    acquire :: IO (Either String QUIC.Stream)
    acquire = withMVar remoteState $ \case
      RemoteEndPointInit -> pure . Left $ "handleIncomingMessages (init)"
      RemoteEndPointClosed -> pure . Left $ "handleIncomingMessages (closed)"
      RemoteEndPointValid validState -> pure . Right $ validState ^. remoteStream

    release :: Either String QUIC.Stream -> IO ()
    release (Left reason) = connectionLost reason
    release (Right _) = closeRemoteEndPoint Incoming remoteEndPoint

    -- One logical connection per stream; clientConnId is always 0.
    connectionId = createConnectionId serverConnId 0

    go = either (const $ pure ()) run

    run stream =
      (messageReceiver stream >>= loop)
        `catch` \(exc :: SomeException) -> case fromException exc of
          Just (_ :: SomeAsyncException) -> throwIO exc
          Nothing -> connectionLost (displayException exc)

    loop nextMessage =
      nextMessage
        >>= \case
          Left errmsg -> connectionLost $ "(handleIncomingMessages) Failed with: " <> errmsg
          Right (Message bytes) -> handleMessage bytes >> loop nextMessage
          Right StreamClosed -> connectionLost "(handleIncomingMessages) Stream closed"
          Right CloseConnection -> do
            mAct <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
              RemoteEndPointInit -> pure (RemoteEndPointClosed, Nothing)
              RemoteEndPointClosed -> pure (RemoteEndPointClosed, Nothing)
              RemoteEndPointValid (ValidRemoteEndPointState _ isClosed _) -> do
                pure (RemoteEndPointClosed, Just $ putMVar isClosed ())
            case mAct of
              Nothing -> pure ()
              Just cleanup -> do
                atomically (writeTQueue ourQueue (ConnectionClosed connectionId))
                cleanup
          Right CloseEndPoint -> do
            -- handleIncomingMessages only runs on incoming remote endpoints, so if
            -- the state was still Valid there is exactly one logical connection to
            -- surface as closed.
            wasValid <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
              RemoteEndPointValid _ -> pure (RemoteEndPointClosed, True)
              other -> pure (other, False)
            when wasValid $
              atomically $
                writeTQueue ourQueue (ConnectionClosed connectionId)

    handleMessage :: [ByteString] -> IO ()
    handleMessage payload =
      atomically (writeTQueue ourQueue (Received connectionId payload))

    connectionLost :: String -> IO ()
    connectionLost reason = do
      wasValid <- modifyMVar remoteState $ \case
        RemoteEndPointValid {} -> pure (RemoteEndPointClosed, True)
        RemoteEndPointInit -> pure (RemoteEndPointClosed, False)
        RemoteEndPointClosed -> pure (RemoteEndPointClosed, False)
      when wasValid $
        atomically
          ( writeTQueue
              ourQueue
              ( ErrorEvent
                  ( TransportError
                      (EventConnectionLost remoteAddress)
                      reason
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
        Right remoteEndPoint -> do
          connAlive <- newIORef True
          pure
            . Right
            $ Connection
              { send = sendConn remoteEndPoint connAlive,
                close = closeConn remoteEndPoint connAlive
              }
  where
    ourAddress = ourEndPoint ^. localAddress
    sendConn remoteEndPoint connAlive packets =
      readMVar (remoteEndPoint ^. remoteEndPointState) >>= \case
        RemoteEndPointInit -> undefined
        RemoteEndPointValid vst ->
          readIORef connAlive >>= \case
            False -> pure . Left $ TransportError SendClosed "Connection closed"
            True ->
              sendMessage (vst ^. remoteStream) packets
                <&> first (TransportError SendFailed . show)
        RemoteEndPointClosed -> do
          readIORef connAlive >>= \case
            -- This is normal. If the remote endpoint closes up while we have
            -- an outgoing connection (CloseEndPoint or CloseSocket message),
            -- we'll post the connection lost event but we won't update these
            -- 'connAlive' IORefs.
            False -> pure . Left $ TransportError SendClosed "Connection closed"
            True -> pure . Left $ TransportError SendFailed "Remote endpoint closed"
    closeConn remoteEndPoint connAlive = do
      mCleanup <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
        RemoteEndPointValid vst@(ValidRemoteEndPointState stream isClosed _) -> do
          readIORef connAlive >>= \case
            False -> pure (RemoteEndPointValid vst, Nothing)
            True -> do
              writeIORef connAlive False
              -- Run cleanup OUTSIDE the MVar modification. tryPutMVar keeps this
              -- safe against races with the finally in streamToEndpoint that can
              -- also signal isClosed on QUIC.Client.run exit.
              let cleanup = do
                    _ <- sendCloseConnection stream
                    _ <- tryPutMVar isClosed ()
                    pure ()
              pure (RemoteEndPointClosed, Just cleanup)
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
