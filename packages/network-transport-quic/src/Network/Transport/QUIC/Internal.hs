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

import Control.Concurrent (killThread)
import Control.Concurrent.STM (atomically, newTQueueIO, readTVarIO, stateTVar)
import Control.Concurrent.STM.TQueue (
    TQueue,
    readTQueue,
    writeTQueue,
 )
import Control.Concurrent.STM.TVar (modifyTVar')
import Control.Exception (Exception (displayException), IOException, catch, throwIO, try)
import Control.Monad (unless, void)
import Data.Bifunctor (Bifunctor (first))
import Data.Binary qualified as Binary (decodeOrFail, encode)
import Data.Bits (shiftL, (.|.))
import Data.Bool (bool)
import Data.ByteString (StrictByteString, fromStrict)
import Data.ByteString qualified as BS
import Data.Function ((&))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Lens.Micro.Platform ((%~), (+~))
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
import Network.Transport.QUIC.Internal.Client (ClientAction (..), forkClient)
import Network.Transport.QUIC.Internal.Configuration (credentialLoadX509)
import Network.Transport.QUIC.Internal.Messaging (MessageReceived (..), decodeMessage, encodeMessage, receiveMessage, recvAck, sendAck, sendCloseConnection, sendMessage)
import Network.Transport.QUIC.Internal.QUICAddr (EndPointId, QUICAddr (..), decodeQUICAddr, encodeQUICAddr)
import Network.Transport.QUIC.Internal.QUICTransport (
    LocalEndPoint (Closed, Open),
    OpenLocalEndPoint,
    QUICStreamId,
    QUICTransport,
    RemoteEndPoint (RemoteEndPoint),
    closeLocalEndpoint,
    localConnections,
    localEndPoints,
    newLocalEndPoint,
    newQUICTransport,
    nextQUICStreamId,
    openLocalAddress,
    openLocalEndPointId,
    openLocalQueue,
    openLocalState,
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
createTransport host port creds = do
    -- TODO: resolve host and port
    quicTransport <- newQUICTransport host port

    serverThread <-
        forkServer
            host
            port
            creds
            throwIO
            throwIO
            (handleNewStream quicTransport)

    pure $
        Transport
            { newEndPoint = newTQueueIO >>= newEndpoint quicTransport creds
            , closeTransport = killThread serverThread
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
                Right (_, _, remoteEndPointAddress) -> do
                    state <- readTVarIO (quicTransport ^. transportState)

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
                                (connectionId, streamId) <- allocateConnectionId ourEndPoint remoteEndPointAddress

                                -- Sending an ack is important, because otherwise
                                -- the client may start sending messages well before we
                                -- start being able to receive them
                                sendAck stream

                                -- If we've reached this stage, the connection handhake succeeded
                                handleIncomingMessages ourEndPoint remoteEndPointAddress (connectionId, streamId)
  where
    handleIncomingMessages :: OpenLocalEndPoint -> EndPointAddress -> (ConnectionId, QUICStreamId) -> IO ()
    handleIncomingMessages ourEndPoint remoteEndPointAddress (connectionId, streamId) =
        go `catch` prematureExit
      where
        ourId = ourEndPoint ^. openLocalEndPointId
        ourQueue = ourEndPoint ^. openLocalQueue

        go =
            receiveMessage stream
                >>= \case
                    Right (Message eid bytes) -> handleMessage eid bytes >> go
                    Left errmsg -> do
                        atomically writeConnectionClosedSTM

                        throwIO $ userError $ "(handleIncomingMessages) Failed with: " <> errmsg
                    Right StreamClosed -> do
                        atomically $ do
                            modifyTVar'
                                (ourEndPoint ^. openLocalState)
                                (\st -> st & localConnections %~ Map.delete (remoteEndPointAddress, streamId))

                            writeConnectionClosedSTM
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
                            (EventConnectionLost remoteEndPointAddress)
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
makeConnectionId :: EndPointId -> QUICStreamId -> ConnectionId
makeConnectionId ourId streamId =
    fromIntegral ourId `shiftL` 32 .|. fromIntegral streamId

newConnection ::
    OpenLocalEndPoint ->
    NonEmpty Credential ->
    EndPointAddress ->
    Reliability ->
    ConnectHints ->
    IO (Either (TransportError ConnectErrorCode) Connection)
newConnection ourEndPoint creds remoteEndPointAddress _reliability _connectHints = do
    if ourEndPoint ^. openLocalAddress == remoteEndPointAddress
        then selfConnect
        else case decodeQUICAddr remoteEndPointAddress of
            Left errmsg ->
                pure $
                    Left $
                        TransportError
                            ConnectNotFound
                            ("Could not decode QUIC address: " <> errmsg)
            Right (QUICAddr remoteHostname remotePort remoteEndPointId) -> do
                connectionIsLive <- newIORef True

                clientSend <-
                    forkClient
                        remoteHostname
                        remotePort
                        creds
                        ( \stream -> do
                            -- Handshake on connection creation, which simply involves
                            -- sending our address over
                            sendMessage
                                stream
                                remoteEndPointId
                                [ BS.toStrict $
                                    Binary.encode (ourEndPoint ^. openLocalAddress)
                                ]
                                >>= \case
                                    Left exc -> throwIO exc -- handshake failed
                                    Right _ -> pure ()

                            -- Server acknowledgement that the handshake is complete
                            -- means that we cannot send messages until the server
                            -- is ready for them
                            recvAck stream
                        )
                        (`sendMessage` remoteEndPointId)
                        (`sendCloseConnection` remoteEndPointId)
                        (\e -> writeIORef connectionIsLive False >> throwIO e)
                        (writeIORef connectionIsLive False)

                pure $
                    Right $
                        Connection
                            { send = \messages ->
                                whenLive
                                    connectionIsLive
                                    (Left $ TransportError SendClosed "connection is closed")
                                    (first (TransportError SendFailed . show) <$> clientSend (ActionSendMessages messages))
                            , close =
                                writeIORef connectionIsLive False
                                    >> void (clientSend ActionCloseClient)
                            }
  where
    selfConnect = do
        -- Normally, allocateConnectionId is used for inbound connections.
        -- However, in the case of self-connections, there is no concept of
        -- a server listening for connections; we must emit the same
        -- events here, as the sender
        (connectionId, _) <- allocateConnectionId ourEndPoint (ourEndPoint ^. openLocalAddress)

        connectionIsLive <- newIORef True

        pure $
            Right $
                Connection
                    { send = \messages ->
                        whenLive
                            connectionIsLive
                            (Left $ TransportError SendClosed "connection is closed")
                            (fmap Right <$> atomically $ writeTQueue (ourEndPoint ^. openLocalQueue) $ Received connectionId messages)
                    , close =
                        writeIORef connectionIsLive False
                            >> atomically (writeTQueue (ourEndPoint ^. openLocalQueue) $ ConnectionClosed connectionId)
                    }

-- | Run an IO action only if the IORef is `True`. Otherwise, return the provided error.
whenLive :: IORef Bool -> a -> IO a -> IO a
whenLive connectionIsLive whenConnectionIsClosed whenConnectionIsLive =
    readIORef connectionIsLive
        >>= bool
            (pure whenConnectionIsClosed)
            whenConnectionIsLive

{- | This function allocates a 'ConnectionId' for an inbound connection.

We factor out this logic of allocating a 'ConnectionId'
because we must do this for self-connections and for remote connections.

This function is also responsible for emitting the 'ConnectionOpened' event
-}
allocateConnectionId :: OpenLocalEndPoint -> EndPointAddress -> IO (ConnectionId, QUICStreamId)
allocateConnectionId ourEndPoint remoteEndPointAddress = do
    streamId <- atomically $ do
        streamId <-
            stateTVar
                (ourEndPoint ^. openLocalState)
                ( \st ->
                    ( st ^. nextQUICStreamId
                    , st
                        & localConnections %~ Map.insert (remoteEndPointAddress, st ^. nextQUICStreamId) (RemoteEndPoint remoteEndPointAddress)
                        & nextQUICStreamId +~ 1
                    )
                )

        let connectionId = makeConnectionId (ourEndPoint ^. openLocalEndPointId) streamId

        writeTQueue
            (ourEndPoint ^. openLocalQueue)
            ( ConnectionOpened
                connectionId
                ReliableOrdered
                remoteEndPointAddress
            )

        pure streamId

    pure (makeConnectionId (ourEndPoint ^. openLocalEndPointId) streamId, streamId)