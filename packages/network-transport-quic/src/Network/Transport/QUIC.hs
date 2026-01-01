module Network.Transport.QUIC
  ( -- * Main interface
    createTransport,

    -- ** Transport configuration
    QUICTransportConfig (..),
    defaultQUICTransportConfig,

    -- ** Re-export to generate credentials
    Credential,
    credentialLoadX509,
  )
where

import Network.Transport.QUIC.Internal
  ( -- \* Re-export to generate credentials
    Credential,
    createTransport,
    credentialLoadX509,
    defaultQUICTransportConfig,
  )
import Network.Transport.QUIC.Internal.QUICTransport (QUICTransportConfig (..))
