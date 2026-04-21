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
import Control.Concurrent.MVar (MVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, bracket, catch, finally, mask, mask_, throwIO)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Client qualified as QUIC.Client
import Network.Transport (ConnectErrorCode (ConnectNotFound), EndPointAddress, TransportError (..))
import Network.Transport.QUIC.Internal.Configuration (Credential, mkClientConfig)
import Network.Transport.QUIC.Internal.Messaging (ClientConnId, MessageReceived (..), handshake, receiveMessage)
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (QUICAddr), decodeQUICAddr)

streamToEndpoint ::
  NonEmpty Credential ->
  -- | Validate credentials
  Bool ->
  -- | Our address
  EndPointAddress ->
  -- | Their address
  EndPointAddress ->
  -- | Client-allocated connection id to send as part of the handshake
  ClientConnId ->
  -- | Called when the QUIC connection or stream ends without us having initiated the
  -- close. Must be idempotent (the caller typically gates on remote endpoint state so
  -- that repeated invocations are safe) — this handler is invoked from multiple sites
  -- (peer-initiated close signal, QUIC.Client.run exception, thread finally) to cover
  -- every termination path.
  IO () ->
  IO
    ( Either
        (TransportError ConnectErrorCode)
        ( MVar ()
        , -- \^ put '()' to close the stream
          QUIC.Stream
        )
    )
streamToEndpoint creds validateCreds ourAddress theirAddress clientConnId onConnLoss =
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
                handshake (ourAddress, theirAddress) clientConnId stream
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
              (\(_ :: SomeException) -> pure ())
              `finally` onConnLoss

      streamOrError <- takeMVar streamMVar

      pure $ (doneMVar,) <$> streamOrError
 where
  listenForClose :: QUIC.Stream -> MVar () -> IO ()
  listenForClose stream doneMVar =
    receiveMessage stream
      >>= \case
        -- Any message from the peer on this stream means we're done listening.
        -- Peer-initiated closes (StreamClosed/CloseEndPoint) additionally call
        -- onConnLoss; the idempotent gate in the handler dedupes with the finally
        -- that also fires on QUIC.Client.run exit.
        --
        -- Mask signalling+onConnLoss as an atomic pair: tryPutMVar unblocks
        -- runClient's takeMVar, which causes withAsync to cancel this thread.
        -- Without mask, the async ThreadKilled can fire partway through
        -- onConnLoss, dropping the ErrorEvent. The finally in the parent thread
        -- is a backup but cannot recover if surfaceConnectionLost already
        -- transitioned the remote state to Closed.
        Right StreamClosed -> mask_ $ do
          _ <- tryPutMVar doneMVar ()
          onConnLoss
        Right (CloseConnection _) ->
          -- Peer closed the logical connection cleanly; no ErrorEvent.
          () <$ tryPutMVar doneMVar ()
        Right CloseEndPoint -> mask_ $ do
          _ <- tryPutMVar doneMVar ()
          onConnLoss
        other -> throwIO . userError $ "Unexpected incoming message to client: " <> show other
