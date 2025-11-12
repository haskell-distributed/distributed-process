{-# LANGUAGE OverloadedStrings #-}

module Network.Transport.QUIC.Internal.Configuration (
    mkClientConfig,
    mkServerConfig,

    -- * Re-export to generate credentials
    Credential,
    TLS.credentialLoadX509,
) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Network.QUIC.Client (ClientConfig (ccALPN, ccValidate), ccPortName, ccServerName, defaultClientConfig)
import Network.QUIC.Internal (ServerConfig (scALPN), ccCredentials)
import Network.QUIC.Server (ServerConfig (scAddresses, scCredentials, scSessionManager, scUse0RTT), defaultServerConfig)
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
            , ccALPN = \_version -> pure (Just ["perf"])
            , ccValidate = False
            , ccCredentials = Credentials (NonEmpty.toList creds)
            -- , ccWatchDog = True
            -- , -- The following two parameters are for debugging. TODO: turn off by default
            --   ccDebugLog = True
            -- , ccKeyLog = putStrLn
            }

mkServerConfig ::
    HostName ->
    ServiceName ->
    NonEmpty Credential ->
    IO ServerConfig
mkServerConfig host port creds = do
    tlsSessionManager <- TLS.sessionManager

    pure $
        defaultServerConfig
            { scAddresses = [(read host, read port)]
            , scSessionManager = tlsSessionManager
            , scCredentials = Credentials (NonEmpty.toList creds)
            , scALPN = Just $ \_version _protocols -> pure "perf"
            , scUse0RTT = True
            -- TODO: send heartbeats regularly
            -- , scParameters =
            --     (scParameters defaultServerConfig)
            --         { maxIdleTimeout = Milliseconds 1000
            --         }
            }