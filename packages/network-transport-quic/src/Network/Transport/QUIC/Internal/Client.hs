{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal.Client
  ( PeerConnection (..),
    connectToPeer,
    openStream,
    superviseStream,
    closeTimeout,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeAsyncException, SomeException, catch, displayException, finally, fromException, mask_, throwIO, try)
import Control.Monad (void)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Client qualified as QUIC.Client
import Network.Transport (ConnectErrorCode (ConnectFailed, ConnectNotFound), EndPointAddress, TransportError (..))
import Network.Transport.QUIC.Internal.Configuration (Credential, mkClientConfig)
import Network.Transport.QUIC.Internal.Messaging (MessageReceived (..), closeTimeout, handshake, receiveMessage)
import Network.Transport.QUIC.Internal.QUICAddr (QUICAddr (QUICAddr), decodeQUICAddr)
import System.Timeout (timeout)

data PeerConnection = PeerConnection
  { peerQUICConnection :: !QUIC.Connection,
    peerShutdown :: !(MVar ())
  }

-- | Like 'try', but asynchronous exceptions (cancellation, timeouts) propagate.
tryAny :: IO a -> IO (Either SomeException a)
tryAny act =
  try act >>= \case
    Left exc | Just (_ :: SomeAsyncException) <- fromException exc -> throwIO exc
    other -> pure other

-- | Establish a QUIC connection to the host of the given endpoint.
connectToPeer ::
  NonEmpty Credential ->
  -- | Validate credentials
  Bool ->
  -- | Their address
  EndPointAddress ->
  -- | Called exactly once when the QUIC connection is gone, whatever the reason
  -- (including having failed to establish it). Must not block.
  IO () ->
  IO (Either (TransportError ConnectErrorCode) PeerConnection)
connectToPeer creds validateCreds theirAddress onLost =
  case decodeQUICAddr theirAddress of
    Left errmsg -> pure $ Left (TransportError ConnectNotFound errmsg)
    Right (QUICAddr hostname servicename _) -> do
      clientConfig <- mkClientConfig hostname servicename creds validateCreds

      connMVar <- newEmptyMVar
      shutdown <- newEmptyMVar

      let failed :: String -> IO ()
          failed msg = void $ tryPutMVar connMVar (Left $ TransportError ConnectNotFound msg)

      _ <-
        forkIO $
          ( ( QUIC.Client.run clientConfig $ \conn -> do
                QUIC.waitEstablished conn
                putMVar connMVar (Right $ PeerConnection conn shutdown)
                takeMVar shutdown
            )
              `catch` (\(exc :: SomeException) -> failed (displayException exc))
          )
            `finally` (failed "connection closed" >> onLost)

      takeMVar connMVar

openStream ::
  PeerConnection ->
  -- | Our address
  EndPointAddress ->
  -- | Their address
  EndPointAddress ->
  IO (Either (TransportError ConnectErrorCode) QUIC.Stream)
openStream peer ourAddress theirAddress =
  tryAny (QUIC.stream (peerQUICConnection peer)) >>= \case
    Left exc -> pure $ Left (TransportError ConnectFailed (displayException exc))
    Right stream ->
      tryAny (handshake (ourAddress, theirAddress) stream) >>= \case
        Right (Right ()) -> pure (Right stream)
        Right (Left ()) -> abandon stream >> pure (Left (TransportError ConnectNotFound "handshake failed"))
        Left exc -> abandon stream >> pure (Left (TransportError ConnectFailed (displayException exc)))
  where
    abandon = void . tryAny . QUIC.closeStream

superviseStream ::
  QUIC.Stream ->
  -- | Put '()' to request that the stream be closed
  MVar () ->
  -- | Filled when the stream is closed
  MVar () ->
  -- | Called when the stream ends without us having asked for it.
  IO () ->
  -- | Called when the stream is finished with
  IO () ->
  IO ()
superviseStream stream closeRequested drained onConnLoss onFinished =
  void . forkIO $
    withAsync listenForClose (\listener -> takeMVar closeRequested >> drain listener)
      `finally` (void (timeout closeTimeout (tryAny (QUIC.closeStream stream))) >> tryPutMVar drained () >> onFinished)
  where
    drain listener =
      void . timeout closeTimeout . tryAny $ do
        QUIC.shutdownStream stream
        wait listener

    listenForClose :: IO ()
    listenForClose =
      ( receiveMessage stream
          >>= \case
            -- Peer-initiated closes (StreamClosed/CloseEndPoint) additionally call
            -- onConnLoss; its idempotent gate dedupes with other termination paths.
            --
            -- Mask signalling+onConnLoss as an atomic pair: tryPutMVar unblocks
            -- the thread which cancels us. Without mask, the cancellation could fire
            -- partway through onConnLoss, dropping the ErrorEvent.
            Right StreamClosed -> lost
            Right CloseConnection ->
              -- Peer closed the logical connection cleanly; no ErrorEvent.
              void $ tryPutMVar closeRequested ()
            Right CloseEndPoint -> lost
            other -> throwIO . userError $ "Unexpected incoming message to client: " <> show other
      )
        `catch` \(exc :: SomeException) -> case fromException exc of
          Just (_ :: SomeAsyncException) -> throwIO exc
          Nothing -> lost -- e.g. the QUIC connection failed
    lost = mask_ $ tryPutMVar closeRequested () >> onConnLoss
