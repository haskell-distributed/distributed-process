module Network.Transport.QUIC.Internal.TLS (
    -- * TLS session manager
    sessionManager,

    -- * Loading TLS credentials
    credentialLoadX509,
) where

import Network.TLS (SessionManager, credentialLoadX509)
import Network.TLS.SessionManager (defaultConfig, newSessionManager)

sessionManager :: IO SessionManager
sessionManager = newSessionManager defaultConfig