{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal.Server (forkServer) where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Exception (SomeException, catch, mask, mask_)
import Data.List.NonEmpty (NonEmpty)
import Network.QUIC qualified as QUIC
import Network.QUIC.Server qualified as QUIC.Server
import Network.Socket (HostName, ServiceName)
import Network.Transport.QUIC.Internal.Configuration (Credential, mkServerConfig)

forkServer ::
    HostName ->
    ServiceName ->
    NonEmpty Credential ->
    -- | Error handler that runs whenever an exception is thrown inside
    -- the thread that accepted an incoming connection
    (SomeException -> IO ()) ->
    -- | Termination handler that runs if the server thread catches an exception
    (SomeException -> IO ()) ->
    -- | Request handler
    (QUIC.Stream -> IO ()) ->
    IO ThreadId
forkServer host port creds errorHandler terminationHandler requestHandler = do
    -- TODO: what's the point of using 'getAddrInfo' and 'getNameInfo'
    -- if we already have the hostname and servicename?
    serverConfig <- mkServerConfig host port creds

    let acceptConnection :: QUIC.Connection -> IO ()
        acceptConnection conn = mask $ \restore -> do
            QUIC.waitEstablished conn
            stream <- QUIC.acceptStream conn

            catch
                (restore (requestHandler stream))
                (\exc -> QUIC.closeStream stream >> errorHandler exc)

    -- We have to make sure that the exception handler is
    -- installed /before/ any asynchronous exception occurs. So we mask_, then
    -- forkIOWithUnmask (the child thread inherits the masked state from the parent), then
    -- unmask only inside the catch.
    --
    -- See the documentation for `forkIOWithUnmask`.
    mask_ $
        forkIOWithUnmask $
            \unmask ->
                catch
                    (unmask $ QUIC.Server.run serverConfig (\conn -> catch (acceptConnection conn) errorHandler))
                    terminationHandler
