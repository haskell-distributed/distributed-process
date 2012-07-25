module Network.Azure.ServiceManagement 
  (
    -- * Submitting requests
    SubscriptionId(SubscriptionId)
  , azureRequest
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

newtype SubscriptionId = SubscriptionId { unSubscriptionId :: String }

azureRequest :: SubscriptionId -> X509 -> PrivateKey -> String -> IO ByteString
azureRequest sid cert pkey subURL = do
  req <- parseUrl ( "https://management.core.windows.net/" 
                 ++ unSubscriptionId sid
                 ++ subURL
                  )
  withManager $ \manager -> do
    let req' = req {
        clientCertificates = [ (cert, Just pkey) ]
      , requestHeaders     = [ (CI.mk $ BSC.pack "x-ms-version", BSC.pack "2010-10-28")
                             , (CI.mk $ BSC.pack "content-type", BSC.pack "application/xml")
                             ]
      }
    Response _ _ _ lbs <- httpLbs req' manager 
    return lbs
