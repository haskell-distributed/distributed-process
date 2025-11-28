{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Network.Transport.QUIC.Internal.Client (
    streamToEndpoint,
) where

import Control.Concurrent (forkIOWithUnmask, newEmptyMVar)
import Control.Concurrent.MVar (MVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, catch, mask, mask_, throwIO)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Client qualified as QUIC.Client
import Network.Transport (ConnectErrorCode (ConnectNotFound), EndPointAddress, TransportError (..))
import Network.Transport.QUIC.Internal.Configuration (Credential, mkClientConfig)
import Network.Transport.QUIC.Internal.Messaging (handshake)
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (QUICAddr), decodeQUICAddr)

streamToEndpoint ::
    NonEmpty Credential ->
    -- | Our address
    EndPointAddress ->
    -- | Their address
    EndPointAddress ->
    IO
        ( Either
            (TransportError ConnectErrorCode)
            ( MVar ()
            , -- \^ put '()' to close the stream
              QUIC.Stream
            )
        )
streamToEndpoint creds ourAddress theirAddress =
    case decodeQUICAddr theirAddress of
        Left errmsg -> pure $ Left (TransportError ConnectNotFound errmsg)
        Right (QUICAddr hostname servicename _) -> do
            clientConfig <- mkClientConfig hostname servicename creds

            streamMVar <- newEmptyMVar
            doneMVar <- newEmptyMVar

            let runClient :: QUIC.Connection -> IO ()
                runClient conn = mask $ \restore -> do
                    QUIC.waitEstablished conn
                    restore $
                        bracket (QUIC.stream conn) QUIC.closeStream $ \stream -> do
                            handshake (ourAddress, theirAddress) stream

                            putMVar streamMVar stream
                            takeMVar doneMVar

            _ <- mask_ $
                forkIOWithUnmask $
                    \unmask ->
                        catch
                            ( unmask $
                                QUIC.Client.run
                                    clientConfig
                                    ( \conn ->
                                        catch
                                            (runClient conn)
                                            (throwIO @SomeException)
                                    )
                            )
                            (throwIO @SomeException)

            stream <- takeMVar streamMVar

            pure $ Right (doneMVar, stream)
