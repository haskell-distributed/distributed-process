{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal.Client (
    forkClient,
    ClientAction (..),
) where

import Control.Concurrent (forkIOWithUnmask, newEmptyMVar)
import Control.Concurrent.MVar (putMVar, takeMVar)
import Control.Exception (SomeException, catch, mask, mask_)
import Data.ByteString (StrictByteString)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Client qualified as QUIC.Client
import Network.Socket (HostName, ServiceName)
import Network.Transport.QUIC.Internal.Configuration (Credential, mkClientConfig)

data ClientAction
    = ActionCloseClient
    | ActionSendMessages [StrictByteString]

forkClient ::
    HostName ->
    ServiceName ->
    NonEmpty Credential ->
    -- | Handshake protocol. No messages can be sent until
    -- this program completes
    (QUIC.Stream -> IO ()) ->
    -- | Function to send messages over a QUIC stream
    (QUIC.Stream -> [StrictByteString] -> IO (Either QUIC.QUICException ())) ->
    -- | Function to run on a 'ActionCloseClient' client action
    (QUIC.Stream -> IO (Either QUIC.QUICException ())) ->
    -- | Error handler that runs whenever an exception is thrown inside
    -- the thread that connected to a server
    (SomeException -> IO ()) ->
    -- | Termination handler; action to run when the client function returns normally
    -- | Client function
    IO () ->
    IO (ClientAction -> IO (Either QUIC.QUICException ()))
forkClient host port creds handshake sendMessages closeConnection errorHandler terminationHandler = do
    clientConfig <- mkClientConfig host port creds

    actionMVar <- newEmptyMVar
    resultMVar <- newEmptyMVar

    let runClient :: QUIC.Connection -> IO ()
        runClient conn = mask $ \restore -> do
            QUIC.waitEstablished conn
            stream <- QUIC.stream conn

            handshake stream

            catch
                (restore (clientFunction stream actionMVar resultMVar))
                (\(_ :: SomeException) -> QUIC.closeStream stream)

            QUIC.closeStream stream

            terminationHandler

    _ <- mask_ $
        forkIOWithUnmask $
            \unmask ->
                catch
                    (unmask $ QUIC.Client.run clientConfig (\conn -> catch (runClient conn) errorHandler))
                    errorHandler

    pure $ \clientAction -> putMVar actionMVar clientAction >> takeMVar resultMVar
  where
    -- The whole point of this function is that we need to be able to
    -- get errors synchronously, hence the takeMVar -> putMVar loop
    clientFunction stream actionMVar resultMVar = do
        takeMVar actionMVar >>= \case
            ActionCloseClient -> closeConnection stream >>= putMVar resultMVar
            ActionSendMessages messages -> do
                sendMessages stream messages
                    >>= putMVar resultMVar
                    >> clientFunction stream actionMVar resultMVar
