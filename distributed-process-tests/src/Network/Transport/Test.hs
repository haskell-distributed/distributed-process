module Network.Transport.Test where

import qualified Network.Transport as NT
import Data.Typeable (Typeable)

-- | Extra operations required of transports for the purposes of testing.
data TestTransport = TestTransport
  { -- | The transport to use for testing.
    testTransport :: NT.Transport
    -- | IO action to perform to simulate losing a connection.
  , testBreakConnection :: NT.EndPointAddress -> NT.EndPointAddress -> IO ()
  } deriving (Typeable)
