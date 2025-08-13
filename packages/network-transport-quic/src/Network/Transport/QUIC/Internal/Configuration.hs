

module Network.Transport.QUIC.Internal.Configuration (
    mkClientConfig,
    mkServerConfig,

    -- * Re-export to generate credentials
    Credential,
    TLS.credentialLoadX509,
) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Network.QUIC.Client (ClientConfig(ccValidate), ccPortName, ccServerName, defaultClientConfig)
import Network.QUIC.Internal (ServerConfig, ccCredentials)
import Network.QUIC.Server (ServerConfig (scCredentials, scSessionManager), defaultServerConfig)
import Network.Socket (HostName, ServiceName)
import Network.TLS (Credential, Credentials (Credentials))
import Network.Transport.QUIC.Internal.TLS qualified as TLS

mkClientConfig ::
    HostName ->
    ServiceName ->
    NonEmpty Credential ->
    IO ClientConfig
mkClientConfig host port creds = do
    pure $
        defaultClientConfig
            { ccServerName = host
            , ccPortName = port
            , ccValidate = False
            , ccCredentials = Credentials (NonEmpty.toList creds)
            }

mkServerConfig ::
    NonEmpty Credential ->
    IO ServerConfig
mkServerConfig creds = do
    tlsSessionManager <- TLS.sessionManager

    pure $
        defaultServerConfig
            { scSessionManager = tlsSessionManager
            , scCredentials = Credentials (NonEmpty.toList creds)
            }
