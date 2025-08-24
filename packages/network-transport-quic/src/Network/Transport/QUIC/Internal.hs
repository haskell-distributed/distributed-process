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
    encodeMessage,
) where

import Control.Concurrent (killThread)
import Control.Concurrent.STM (atomically, newTQueueIO, readTVar, readTVarIO, throwSTM)
import Control.Concurrent.STM.TQueue (
    TQueue,
    readTQueue,
    writeTQueue,
 )
import Control.Concurrent.STM.TVar (modifyTVar')
import Control.Exception (Exception (displayException), IOException, catch, throwIO, try)
import Control.Monad (forever, unless, when)
import Data.Binary qualified as Binary (decodeOrFail, encode)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (StrictByteString, fromStrict)
import Data.ByteString qualified as BS
import Data.Function ((&))
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Debug.Trace
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
    Reliability,
    ResolveMulticastGroupErrorCode (ResolveMulticastGroupUnsupported),
    Transport (..),
    TransportError (..),
 )
import Network.Transport.QUIC.Internal.Client (forkClient)
import Network.Transport.QUIC.Internal.Configuration (credentialLoadX509)
import Network.Transport.QUIC.Internal.Messaging (decodeMessage, encodeMessage, receiveMessage, recvAck, sendAck, sendMessage)
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (..), decodeQUICAddr, encodeQUICAddr)
import Network.Transport.QUIC.Internal.QUICTransport (
    EndPointId (EndPointId),
    LocalEndPoint,
    QUICTransport,
    RemoteEndPoint (RemoteEndPoint),
    localAddress,
    localConnections,
    localEndPointId,
    localEndPoints,
    localQueue,
    localState,
    newLocalEndPoint,
    newQUICTransport,
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
            (\exc -> traceM ("handlerError " <> show exc) >> throwIO exc)
            (\exc -> traceM ("terminationError " <> show exc) >> throwIO exc)
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
        Right (endpointId, payload) -> do
            case Binary.decodeOrFail (fromStrict payload) of
                Left (_, _, errmsg) ->
                    throwIO (userError $ "(handleNewStream) remote endpoint address in handshake could not be decoded: " <> errmsg)
                Right (_, _, remoteEndPointAddress) -> do
                    state <- readTVarIO (quicTransport ^. transportState)
                    ourEndpoint <-
                        maybe
                            ( throwIO
                                ( userError $
                                    "(handleNewStream) Unknown endpointId " <> show endpointId
                                )
                            )
                            pure
                            (Map.lookup endpointId (state ^. localEndPoints))

                    atomically $ do
                        localEndPointState <- readTVar (ourEndpoint ^. localState)
                        let knownRemoteEndpoints = localEndPointState ^. localConnections

                        when (remoteEndPointAddress `Map.member` knownRemoteEndpoints) $
                            throwSTM (userError "(handleNewStream) a connection already exists")

                        modifyTVar'
                            (ourEndpoint ^. localState)
                            (\st -> st & localConnections %~ Map.insert remoteEndPointAddress (RemoteEndPoint remoteEndPointAddress))

                    -- Sending an ack is important, because otherwise
                    -- the client may start sending messages well before we
                    -- start being able to receive them
                    sendAck stream

                    traceM "CH handshake complete"
                    -- If we've reached this stage, the connection handhake succeeded
                    handleIncomingMessages ourEndpoint remoteEndPointAddress
  where
    handleIncomingMessages :: LocalEndPoint -> EndPointAddress -> IO ()
    handleIncomingMessages ourEndPoint remoteEndPointAddress =
        go `catch` prematureExit
      where
        ourId = ourEndPoint ^. localEndPointId
        ourQueue = ourEndPoint ^. localQueue
        streamId = QUIC.streamId stream

        -- This connection ID is expected to be unique in the transport.
        -- We do this by combining this endpoint's ID (unique among
        -- the transport) and the stream ID. It's not clear how unique the
        -- stream ID should be, however
        (connectionId :: ConnectionId) =
            fromIntegral ourId `shiftL` 32 .|. fromIntegral streamId

        go =
            trace "receiving" receiveMessage stream
                >>= either
                    (throwIO . userError . (<>) "(handleIncomingMessages) Failed with: ")
                    (uncurry handleMessage)
                >> traceM "Message processed"
                >> go
          where
            handleMessage :: EndPointId -> StrictByteString -> IO ()
            handleMessage eid payload
                | eid /= ourId = throwIO (userError "(handleMessage) Payload directed to the wrong EndPointId")
                | otherwise = traceM "Message received" >> atomically (writeTQueue ourQueue (Received connectionId [payload]))

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
                { receive = atomically (readTQueue (ourEndPoint ^. localQueue))
                , address = ourEndPoint ^. localAddress
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
                , closeEndPoint = undefined
                }

newConnection ::
    LocalEndPoint ->
    NonEmpty Credential ->
    EndPointAddress ->
    Reliability ->
    ConnectHints ->
    IO (Either (TransportError ConnectErrorCode) Connection)
newConnection ourEndPoint creds remoteEndPointAddress _reliability _connectHints = do
    if ourEndPoint ^. localAddress == remoteEndPointAddress
        then undefined -- self-connection
        else case decodeQUICAddr remoteEndPointAddress of
            Left errmsg ->
                pure $
                    Left $
                        TransportError
                            ConnectNotFound
                            ("Could not decode QUIC address: " <> errmsg)
            Right (QUICAddr remoteHostname remotePort remoteEndpointId) -> do
                (clientTid, outgoingQueue) <-
                    forkClient
                        remoteHostname
                        remotePort
                        creds
                        throwIO
                        ( \queue stream -> do
                            traceM "CH handshake started"
                            -- Handshake on connection creation, which simply involves
                            -- sending our address over
                            sendMessage
                                stream
                                (EndPointId remoteEndpointId)
                                [ BS.toStrict $
                                    Binary.encode (ourEndPoint ^. localAddress)
                                ]

                            -- Server acknowledgement that the handshake is complete
                            -- means that we cannot send messages until the server
                            -- is ready for them
                            recvAck stream

                            traceM "CH handshake complete (client)"

                            forever $ do
                                traceM "waiting for new message to send"
                                atomically (readTQueue queue)
                                    >>= sendMessage stream (EndPointId remoteEndpointId)
                                traceM "Message sent"
                        )

                pure $
                    Right $
                        Connection
                            { send = fmap Right . atomically . writeTQueue outgoingQueue
                            , close = killThread clientTid
                            }
