{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Network.Transport.QUIC.Internal.Client (
  streamToEndpoint,
)
where

import Control.Concurrent (forkIOWithUnmask, newEmptyMVar)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (MVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, catch, mask, mask_, throwIO)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Client qualified as QUIC.Client
import Network.Transport (ConnectErrorCode (ConnectNotFound), EndPointAddress, TransportError (..))
import Network.Transport.QUIC.Internal.Configuration (Credential, mkClientConfig)
import Network.Transport.QUIC.Internal.Messaging (MessageReceived (..), handshake, receiveMessage)
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (QUICAddr), decodeQUICAddr)

streamToEndpoint ::
  NonEmpty Credential ->
  -- | Validate credentials
  Bool ->
  -- | Our address
  EndPointAddress ->
  -- | Their address
  EndPointAddress ->
  -- | On exception
  (SomeException -> IO ()) ->
  -- | On a message to forcibly close the connection
  IO () ->
  IO
    ( Either
        (TransportError ConnectErrorCode)
        ( MVar ()
        , -- \^ put '()' to close the stream
          QUIC.Stream
        )
    )
streamToEndpoint creds validateCreds ourAddress theirAddress onExc onCloseForcibly =
  case decodeQUICAddr theirAddress of
    Left errmsg -> pure $ Left (TransportError ConnectNotFound errmsg)
    Right (QUICAddr hostname servicename _) -> do
      clientConfig <- mkClientConfig hostname servicename creds validateCreds

      streamMVar <- newEmptyMVar
      doneMVar <- newEmptyMVar

      let runClient :: QUIC.Connection -> IO ()
          runClient conn = mask $ \restore -> do
            QUIC.waitEstablished conn
            restore $
              bracket (QUIC.stream conn) QUIC.closeStream $ \stream -> do
                handshake (ourAddress, theirAddress) stream
                  >>= either
                    (\_ -> putMVar streamMVar (Left $ TransportError ConnectNotFound "handshake failed"))
                    (\_ -> putMVar streamMVar (Right stream))

                withAsync (listenForClose stream doneMVar) $ \_ ->
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
              onExc

      streamOrError <- takeMVar streamMVar

      pure $ (doneMVar,) <$> streamOrError
 where
  listenForClose :: QUIC.Stream -> MVar () -> IO ()
  listenForClose stream doneMVar =
    receiveMessage stream
      >>= \case
        Right StreamClosed -> do
          putMVar doneMVar ()
        Right (CloseConnection _) -> do
          putMVar doneMVar ()
        Right CloseEndPoint -> do
          putMVar doneMVar ()
          onCloseForcibly
        other -> throwIO . userError $ "Unexpected incoming message to client: " <> show other
