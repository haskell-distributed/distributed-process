{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal (
    createTransport,
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
) where

import Control.Concurrent (forkIO, killThread, modifyMVar_, newEmptyMVar, readMVar)
import Control.Concurrent.MVar (modifyMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.STM (atomically, newTQueueIO)
import Control.Concurrent.STM.TQueue (
    TQueue,
    readTQueue,
    writeTQueue,
 )
import Control.Exception (Exception (displayException), IOException, bracket, throwIO, try)
import Control.Monad (unless)
import Data.Bifunctor (Bifunctor (first))
import Data.Binary qualified as Binary (decodeOrFail)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (StrictByteString, fromStrict)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Lens.Micro.Platform ((%~))
import Network.QUIC qualified as QUIC
import Network.Socket (HostName, ServiceName)
import Network.TLS (Credential)
import Network.Transport (
    ConnectErrorCode (ConnectNotFound),
    ConnectHints,
    Connection (..),
    ConnectionId,
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
import Network.Transport.QUIC.Internal.Messaging (MessageReceived (..), decodeMessage, encodeMessage, receiveMessage, sendAck, sendCloseConnection, sendMessage)
import Network.Transport.QUIC.Internal.QUICAddr (EndPointId, QUICAddr (..), decodeQUICAddr, encodeQUICAddr)
import Network.Transport.QUIC.Internal.QUICTransport (
    ConnectionCounter,
    LocalEndPoint (Closed, Open),
    OpenLocalEndPoint,
    QUICTransport,
    RemoteEndPoint (..),
    RemoteEndPointState (..),
    ValidRemoteEndPointState (..),
    closeLocalEndpoint,
    closeRemoteEndPoint,
    createConnectionTo,
    createRemoteEndPoint,
    foldOpenEndPoints,
    localConnections,
    localEndPoints,
    newLocalEndPoint,
    newQUICTransport,
    openLocalAddress,
    openLocalEndPointId,
    openLocalQueue,
    openLocalState,
    remoteEndPointAddress,
    remoteEndPointState,
    remoteStream,
    transportInputSocket,
    transportState,
    (^.),
 )
import Network.Transport.QUIC.Internal.Server (forkServer)

{- | Create a new Transport based on the QUIC protocol.

Only a single transport should be created per Haskell process
(threads can, and should, create their own endpoints though).
-}
createTransport ::
    HostName ->
    ServiceName ->
    NonEmpty Credential ->
    IO Transport
createTransport host serviceName creds = do
    quicTransport <- newQUICTransport host serviceName

    serverThread <-
        forkServer
            (quicTransport ^. transportInputSocket)
            creds
            throwIO
            throwIO
            (handleNewStream quicTransport)

    pure $
        Transport
            { newEndPoint = newTQueueIO >>= newEndpoint quicTransport creds
            , closeTransport =
                foldOpenEndPoints quicTransport (closeLocalEndpoint quicTransport)
                    >> killThread serverThread
            }

{- | Handle a new incoming connection.

This is the function which:
 1. First initiates a relationship between endpoints, called a /handshake/
 2. then continuously reads from the stream to queue up events for the appropriate endpoint.
-}
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
    receiveMessage stream >>= \case
        Left errmsg -> throwIO (userError $ "(handleNewStream) Could not decode handshake message: " <> errmsg)
        Right StreamClosed -> pure () -- The connection aborts before the handshake
        Right CloseConnection -> pure () -- The connection aborts before the handshake
        Right (Message endpointId payload) -> do
            case Binary.decodeOrFail (fromStrict payload) of
                Left (_, _, errmsg) ->
                    throwIO (userError $ "(handleNewStream) remote endpoint address in handshake could not be decoded: " <> errmsg)
                Right (_, _, remoteAddress) -> do
                    state <- readMVar (quicTransport ^. transportState)

                    maybe
                        ( throwIO
                            ( userError $
                                "(handleNewStream) Unknown endpointId " <> show endpointId
                            )
                        )
                        pure
                        (Map.lookup endpointId (state ^. localEndPoints))
                        >>= \case
                            Closed _ -> throwIO (userError "Endpoint is closed")
                            Open ourEndPoint -> do
                                (remoteEndPoint, connCounter) <- createRemoteEndPoint (Open ourEndPoint) remoteAddress
                                let connectionId = makeConnectionId endpointId connCounter
                                doneMVar <- newEmptyMVar
                                let st =
                                        RemoteEndPointValid $
                                            ValidRemoteEndPointState
                                                { _remoteStream = stream
                                                , _remoteStreamIsClosed = doneMVar -- TODO: this does nothing right now
                                                }
                                modifyMVar_
                                    (remoteEndPoint ^. remoteEndPointState)
                                    ( \case
                                        RemoteEndPointInit -> pure st
                                        _ -> undefined
                                    )

                                -- Sending an ack is important, because otherwise
                                -- the client may start sending messages well before we
                                -- start being able to receive them
                                sendAck stream

                                _ <-
                                    forkIO $
                                        -- If we've reached this stage, the connection handhake succeeded
                                        handleIncomingMessages
                                            ourEndPoint
                                            remoteEndPoint
                                            (connectionId, connCounter)

                                atomically $
                                    writeTQueue
                                        (ourEndPoint ^. openLocalQueue)
                                        ( ConnectionOpened
                                            connectionId
                                            ReliableOrdered
                                            remoteAddress
                                        )

                                takeMVar doneMVar

{- | Infinite loop that listens for messages from the remote endpoint and processes them.

This function assumes that the handshake has been completed.
-}
handleIncomingMessages :: OpenLocalEndPoint -> RemoteEndPoint -> (ConnectionId, ConnectionCounter) -> IO ()
handleIncomingMessages ourEndPoint remoteEndPoint (connectionId, streamId) =
    bracket acquire release go
  where
    ourId = ourEndPoint ^. openLocalEndPointId
    ourQueue = ourEndPoint ^. openLocalQueue
    remoteAddress = remoteEndPoint ^. remoteEndPointAddress
    remoteState = remoteEndPoint ^. remoteEndPointState

    acquire :: IO (Either IOError QUIC.Stream)
    acquire = withMVar remoteState $ \case
        RemoteEndPointInit -> pure . Left $ userError "handleIncomingMessages (init)"
        RemoteEndPointClosed -> pure . Left $ userError "handleIncomingMessages (closed)"
        RemoteEndPointValid validState -> pure . Right $ validState ^. remoteStream

    release :: Either IOError QUIC.Stream -> IO ()
    release (Left err) = closeRemoteEndPoint ourId remoteEndPoint >> prematureExit err
    release (Right _) = closeRemoteEndPoint ourId remoteEndPoint

    go = either prematureExit loop

    loop stream =
        receiveMessage stream
            >>= \case
                Right (Message eid bytes) -> handleMessage eid bytes >> loop stream
                Left errmsg -> do
                    atomically writeConnectionClosedSTM

                    throwIO $ userError $ "(handleIncomingMessages) Failed with: " <> errmsg
                Right StreamClosed -> do
                    modifyMVar_
                        (ourEndPoint ^. openLocalState)
                        (\st -> pure $ st & localConnections %~ Map.delete (remoteAddress, streamId))

                    atomically writeConnectionClosedSTM
                Right CloseConnection ->
                    atomically writeConnectionClosedSTM
      where
        handleMessage :: EndPointId -> StrictByteString -> IO ()
        handleMessage eid payload
            | eid /= ourId = throwIO (userError "(handleMessage) Payload directed to the wrong EndPointId")
            | otherwise = atomically (writeTQueue ourQueue (Received connectionId [payload]))

        writeConnectionClosedSTM =
            writeTQueue
                ourQueue
                (ConnectionClosed connectionId)

    prematureExit :: IOException -> IO ()
    prematureExit exc =
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
    NonEmpty Credential ->
    TQueue Event ->
    IO (Either (TransportError NewEndPointErrorCode) EndPoint)
newEndpoint quicTransport creds newLocalQueue = do
    ourEndPoint <- newLocalEndPoint quicTransport newLocalQueue
    try $
        pure $
            EndPoint
                { receive = atomically (readTQueue (ourEndPoint ^. openLocalQueue))
                , address = ourEndPoint ^. openLocalAddress
                , connect = newConnection ourEndPoint creds
                , newMulticastGroup =
                    pure . Left $
                        TransportError
                            NewMulticastGroupUnsupported
                            "Multicast not supported"
                , resolveMulticastGroup =
                    pure
                        . Left
                        . const
                            ( TransportError
                                ResolveMulticastGroupUnsupported
                                "Multicast not supported"
                            )
                , closeEndPoint =
                    closeLocalEndpoint
                        quicTransport
                        ourEndPoint
                }

-- This connection ID is expected to be unique in the transport.
-- We do this by combining this endpoint's ID (unique among
-- the transport) and the stream ID. It's not clear how unique the
-- stream ID should be, however
makeConnectionId :: EndPointId -> ConnectionCounter -> ConnectionId
makeConnectionId ourId streamId =
    fromIntegral ourId `shiftL` 32 .|. fromIntegral streamId

newConnection ::
    OpenLocalEndPoint ->
    NonEmpty Credential ->
    EndPointAddress ->
    Reliability ->
    ConnectHints ->
    IO (Either (TransportError ConnectErrorCode) Connection)
newConnection ourEndPoint creds remoteAddress _reliability _connectHints = do
    -- Note that in the network-transport-quic design, there is no need
    -- to make a difference between self-connections and "real" connections.
    remoteEndPoint <- createConnectionTo creds (Open ourEndPoint) remoteAddress

    case decodeQUICAddr remoteAddress of
        Left errmsg ->
            pure $
                Left $
                    TransportError
                        ConnectNotFound
                        ("Could not decode QUIC address: " <> errmsg)
        Right (QUICAddr _ _ remoteEndPointId) -> do
            connAlive <- newIORef True
            pure
                . Right
                $ Connection
                    { send = sendConn remoteEndPoint connAlive remoteEndPointId
                    , close = closeConn remoteEndPoint connAlive remoteEndPointId
                    }
  where
    sendConn remoteEndPoint connAlive remoteEndPointId packets =
        readMVar (remoteEndPoint ^. remoteEndPointState) >>= \case
            RemoteEndPointInit -> undefined
            RemoteEndPointValid vst ->
                readIORef connAlive >>= \case
                    False -> throwIO $ TransportError SendClosed "Connection closed"
                    True ->
                        sendMessage (vst ^. remoteStream) remoteEndPointId packets
                            <&> (first (TransportError SendFailed . show))
            RemoteEndPointClosed -> do
                readIORef connAlive >>= \case
                    -- This is normal. If the remote endpoint closes up while we have
                    -- an outgoing connection (CloseEndPoint or CloseSocket message),
                    -- we'll post the connection lost event but we won't update these
                    -- 'connAlive' IORefs.
                    False -> throwIO $ TransportError SendClosed "Connection closed"
                    True -> throwIO $ TransportError SendFailed "Remote endpoint closed"
    closeConn remoteEndPoint connAlive remoteEndPointId = do
        mCleanup <- modifyMVar (remoteEndPoint ^. remoteEndPointState) $ \case
            RemoteEndPointValid vst@(ValidRemoteEndPointState stream isClosed) -> do
                readIORef connAlive >>= \case
                    False -> pure (RemoteEndPointValid vst, Nothing)
                    True -> do
                        writeIORef connAlive False
                        -- We want to run this cleanup action OUTSIDE of the MVar modification
                        let cleanup = sendCloseConnection stream remoteEndPointId >> putMVar isClosed ()
                        pure (RemoteEndPointClosed, Just cleanup)
            _ -> pure (RemoteEndPointClosed, Nothing)

        case mCleanup of
            Nothing -> pure ()
            Just cleanup -> cleanup
