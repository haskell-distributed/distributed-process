module Network.Azure.ServiceManagement 
  ( -- * Submitting requests
    azureRequest
    -- * Re-export functionality from TLS
  , fileReadCertificate
  , fileReadPrivateKey
  ) where

import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Char8 as BSC (pack)
import Network.TLS (PrivateKey)
import Network.TLS.Extra (fileReadCertificate, fileReadPrivateKey)
import Data.Certificate.X509 (X509)
import Network.HTTP.Conduit 
  ( parseUrl
  , clientCertificates
  , requestHeaders
  , withManager
  , Response(Response)
  , httpLbs
  )
import Data.CaseInsensitive as CI (mk)

-- ^ Execute an Azure request
azureRequest :: String      -- ^ Subscription ID
             -> X509        -- ^ X509 certificate
             -> PrivateKey  -- ^ Private key
             -> String      -- ^ Relative path
             -> String      -- ^ Version
             -> IO ByteString
azureRequest sid cert pkey subURL version = do
  req <- parseUrl $ "https://management.core.windows.net/" ++ sid++ subURL
  withManager $ \manager -> do
    let req' = req {
        clientCertificates = [ (cert, Just pkey) ]
      , requestHeaders     = [ (CI.mk $ BSC.pack "x-ms-version", BSC.pack version)
                             , (CI.mk $ BSC.pack "content-type", BSC.pack "application/xml")
                             ]
      }
    Response _ _ _ lbs <- httpLbs req' manager 
    return lbs
