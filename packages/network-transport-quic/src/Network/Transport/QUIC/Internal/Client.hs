{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal.Client (forkClient) where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Concurrent.STM (TQueue, newTQueueIO)
import Control.Exception (SomeException, catch, mask, mask_)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Client qualified as QUIC.Client
import Network.Socket (HostName, ServiceName)
import Network.Transport.QUIC.Internal.Configuration (Credential, mkClientConfig)

forkClient ::
    HostName ->
    ServiceName ->
    NonEmpty Credential ->
    -- | Error handler that runs whenever an exception is thrown inside
    -- the thread that connected to a server
    (SomeException -> IO ()) ->
    -- | Client function
    (TQueue e -> QUIC.Stream -> IO ()) ->
    IO (ThreadId, TQueue e)
forkClient host port creds errorHandler clientFunction = do
    -- TODO: what's the point of using 'getAddrInfo' and 'getNameInfo'
    -- if we already have the hostname and servicename?
    clientConfig <- mkClientConfig host port creds

    outgoingQueue <- newTQueueIO

    let runClient :: QUIC.Connection -> IO ()
        runClient conn = mask $ \restore -> do
            QUIC.waitEstablished conn
            stream <- QUIC.stream conn

            catch
                (restore (clientFunction outgoingQueue stream))
                (\(_ :: SomeException) -> QUIC.closeStream stream)

            QUIC.closeStream stream

    tid <- mask_ $
        forkIOWithUnmask $
            \unmask ->
                catch
                    (unmask $ QUIC.Client.run clientConfig (\conn -> catch (runClient conn) errorHandler))
                    errorHandler

    pure (tid, outgoingQueue)