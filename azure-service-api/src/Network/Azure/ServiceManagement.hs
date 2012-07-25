{-# LANGUAGE Arrows #-}
module Network.Azure.ServiceManagement 
  ( -- * Setup
    AzureSetup(..)
  , azureSetup
    -- * High-level API
  , hostedServices
    -- * Low-level API 
  , azureRequest
  , azureRawRequest
  ) where

import Prelude hiding (id)
import Control.Category (id, (>>>))
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Char8 as BSC (pack)
import Data.ByteString.Lazy.Char8 as BSLC (unpack)
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
import Text.XML.HXT.Core 
  ( runX
  , readString
  , withValidate
  , no
  , XmlTree
  , IOSArrow
  , XNode
  , ArrowXml
  , deep
  , hasName
  , getText
  )

--------------------------------------------------------------------------------
-- Setup                                                                      --
--------------------------------------------------------------------------------

-- | Azure setup 
data AzureSetup = AzureSetup
  { subscriptionId :: String
  , certificate    :: X509
  , privateKey     :: PrivateKey
  , baseURL        :: String
  }

-- | Initialize Azure
azureSetup :: String        -- ^ Subscription ID
           -> String        -- ^ Path to certificate
           -> String        -- ^ Path to private key
           -> IO AzureSetup
azureSetup sid certPath pkeyPath = do
  cert <- fileReadCertificate certPath
  pkey <- fileReadPrivateKey pkeyPath
  return AzureSetup {
      subscriptionId = sid
    , certificate    = cert
    , privateKey     = pkey
    , baseURL        = "https://management.core.windows.net"
    }

--------------------------------------------------------------------------------
-- High-level API                                                             --
--------------------------------------------------------------------------------

hostedServices :: AzureSetup -> IO [(String, String)]
hostedServices setup =
  azureRequest setup "/services/hostedservices" "2012-03-01" $ proc xml -> do 
    hostedService <- deep (hasName "HostedService") -< xml 
    url           <- getTextNode "Url"         -< hostedService
    serviceName   <- getTextNode "ServiceName" -< hostedService
    id -< (url, serviceName)

--------------------------------------------------------------------------------
-- Low-level API                                                              --
--------------------------------------------------------------------------------

-- | Execute an Azure request and parse the XML data 
azureRequest :: AzureSetup
             -> String
             -> String
             -> IOSArrow XmlTree c
             -> IO [c]
azureRequest setup subURL version f = do
  raw <- azureRawRequest setup subURL version
  runX $ readString [withValidate no] (BSLC.unpack raw) >>> f

-- | Execute an Azure request and return the raw data
azureRawRequest :: AzureSetup 
                -> String      -- ^ Relative path
                -> String      -- ^ Version
                -> IO ByteString
azureRawRequest setup subURL version = do
  req <- parseUrl $ baseURL setup ++ "/" ++ subscriptionId setup ++ "/" ++ subURL 
  withManager $ \manager -> do
    let req' = req {
        clientCertificates = [ (certificate setup, Just $ privateKey setup) ]
      , requestHeaders     = [ (CI.mk $ BSC.pack "x-ms-version", BSC.pack version)
                             , (CI.mk $ BSC.pack "content-type", BSC.pack "application/xml")
                             ]
      }
    Response _ _ _ lbs <- httpLbs req' manager 
    return lbs

--------------------------------------------------------------------------------
-- XML convenience functions                                                  --
--------------------------------------------------------------------------------

getTextNode :: ArrowXml a => String -> a XmlTree String
getTextNode node = deep (hasName node) >>> deep getText
