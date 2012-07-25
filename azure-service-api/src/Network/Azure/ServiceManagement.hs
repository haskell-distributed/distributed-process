{-# LANGUAGE Arrows #-}
module Network.Azure.ServiceManagement 
  ( -- * Data types
    HostedService
    -- * Setup
  , AzureSetup(..)
  , azureSetup
    -- * High-level API
  , hostedServices
  , hostedServiceProperties
    -- * Low-level API 
  , azureRequest
  , azureRawRequest
  ) where

import Prelude hiding (id)
import Control.Category (id, (>>>))
import Control.Arrow (arr)
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
  , ArrowXml
  , deep
  , hasName
  , getText
  -- FOR DEBUGGING ONLY
  , writeDocument
  , withIndent
  , yes
  )

--------------------------------------------------------------------------------
-- Data types                                                                 --
--------------------------------------------------------------------------------

newtype HostedService = HostedService { unHostedService :: String }

instance Show HostedService where
  show = unHostedService

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

-- | Get list of available hosted services
hostedServices :: AzureSetup -> IO [HostedService] 
hostedServices setup =
    azureRequest setup subURL "2012-03-01" $ proc xml -> do 
      writeDocument [withIndent yes] "hostedservices.xml" -< xml
      hostedService <- deep (hasName "HostedService") -< xml 
      name <- getTextNode "ServiceName" -< hostedService
      arr HostedService -< name
  where
    subURL = "/services/hostedservices"

-- | Get properties of the given hosted service
hostedServiceProperties :: AzureSetup -> HostedService -> IO [()]
hostedServiceProperties setup (HostedService service) = do
    azureRequest setup subURL "2012-03-01" $ proc xml -> do
      writeDocument [withIndent yes] "properties.xml" -< xml
      id -< ()
  where
    subURL = "/services/hostedservices/" ++ service ++ "?embed-detail=true"

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
