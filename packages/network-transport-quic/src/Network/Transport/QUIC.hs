module Network.Transport.QUIC (
    createTransport,
    QUICAddr (..),

    -- * Re-export to generate credentials
    Credential,
    credentialLoadX509,
) where

import Network.Transport.QUIC.Internal (
    -- \* Re-export to generate credentials
    Credential,
    QUICAddr (..),
    createTransport,
    credentialLoadX509,
 )
