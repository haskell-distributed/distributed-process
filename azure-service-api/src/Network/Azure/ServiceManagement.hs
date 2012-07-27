{-# LANGUAGE Arrows #-}
module Network.Azure.ServiceManagement 
  ( -- * Data types
    HostedService(..)
  , CloudService(..)
  , VirtualMachine(..)
  , Endpoint(..)
    -- * Pure functions
  , vmSshEndpoint 
    -- * Setup
  , AzureSetup(..)
  , azureSetup
    -- * High-level API
  , hostedServices
  , cloudServices 
  ) where

import Prelude hiding (id, (.))
import Control.Category (id, (>>>), (.))
import Control.Arrow (arr)
import Control.Monad (forM)
import Data.ByteString.Char8 as BSC (pack)
import Data.ByteString.Lazy.Char8 as BSLC (unpack)
import Network.TLS (PrivateKey)
import Network.TLS.Extra (fileReadCertificate, fileReadPrivateKey)
import Data.Certificate.X509 (X509)
import Control.Monad.Trans.Resource (ResourceT)
import Control.Monad.IO.Class (liftIO)
import Control.Arrow.ArrowList (listA)
import Network.HTTP.Conduit 
  ( parseUrl
  , clientCertificates
  , requestHeaders
  , withManager
  , Response(Response)
  , httpLbs
  , Manager
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
  , getText
  )
import Text.XML.HXT.XPath (getXPathTrees)

--------------------------------------------------------------------------------
-- Data types                                                                 --
--------------------------------------------------------------------------------

data HostedService = HostedService { 
    hostedServiceName :: String 
  }
  deriving Show

data CloudService = CloudService {
    cloudServiceName :: String 
  , cloudServiceVMs  :: [VirtualMachine]
  }
  deriving Show

data VirtualMachine = VirtualMachine { 
    vmName           :: String
  , vmInputEndpoints :: [Endpoint]
  }
  deriving Show

data Endpoint = Endpoint {
   endpointName :: String
 , endpointPort :: String 
 , endpointVip  :: String
 }
 deriving Show

--------------------------------------------------------------------------------
-- Pure operations                                                            --
--------------------------------------------------------------------------------

vmSshEndpoint :: VirtualMachine -> Endpoint
vmSshEndpoint vm = head 
  [ ep
  | ep <- vmInputEndpoints vm
  , endpointName ep == "SSH"
  ]

--------------------------------------------------------------------------------
-- Setup                                                                      --
--------------------------------------------------------------------------------

-- | Azure setup 
data AzureSetup = AzureSetup
  { subscriptionId :: String
  , certificate    :: X509
  , privateKey     :: PrivateKey
  , baseUrl        :: String
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
    , baseUrl        = "https://management.core.windows.net"
    }

--------------------------------------------------------------------------------
-- High-level API                                                             --
--------------------------------------------------------------------------------

-- | Get a list of virtual machines
cloudServices :: AzureSetup -> IO [CloudService]
cloudServices setup = azureExecute setup $ \exec -> do
  services <- exec hostedServicesRequest
  forM services $ \service -> do
    roles <- exec AzureRequest {
        relativeUrl = "/services/hostedservices/" ++ hostedServiceName service 
                   ++ "?embed-detail=true"
      , apiVersion  = "2012-03-01"
      , parser      = proc xml -> do
          role      <- getXPathTrees "//Role[@type='PersistentVMRole']" -< xml
          name      <- getText . getXPathTrees "/Role/RoleName/text()" -< role
          endpoints <- listA (parseEndpoint . getXPathTrees "//InputEndpoint") -< role
          id -< VirtualMachine name endpoints
      }
    return $ CloudService (hostedServiceName service) roles

-- | Get list of available hosted services
hostedServices :: AzureSetup -> IO [HostedService] 
hostedServices setup = azureExecute setup (\exec -> exec hostedServicesRequest) 

hostedServicesRequest :: AzureRequest HostedService
hostedServicesRequest = AzureRequest 
  { relativeUrl = "/services/hostedservices"
  , apiVersion  = "2012-03-01"
  , parser      = arr HostedService 
                . getText 
                . getXPathTrees "//ServiceName/text()"
  }

parseEndpoint :: ArrowXml t => t XmlTree Endpoint 
parseEndpoint = proc endpoint -> do
  name <- getText . getXPathTrees "//Name/text()" -< endpoint
  port <- getText . getXPathTrees "//Port/text()" -< endpoint
  vip  <- getText . getXPathTrees "//Vip/text()" -< endpoint
  id -< Endpoint name port vip

--------------------------------------------------------------------------------
-- Low-level API                                                              --
--------------------------------------------------------------------------------

data AzureRequest c = AzureRequest {
    relativeUrl :: String
  , apiVersion  :: String
  , parser      :: IOSArrow XmlTree c
  }

azureExecute :: AzureSetup -> ((forall b. AzureRequest b -> ResourceT IO [b]) -> ResourceT IO a) -> IO a
azureExecute setup f = withManager (\manager -> f (go manager)) 
  where
    go :: Manager -> forall b. AzureRequest b -> ResourceT IO [b]
    go manager request = do
      req <- parseUrl $ baseUrl setup 
                     ++ "/" ++ subscriptionId setup 
                     ++ "/" ++ relativeUrl request
      let req' = req {
          clientCertificates = [ (certificate setup, Just $ privateKey setup) ]
        , requestHeaders     = [ (CI.mk $ BSC.pack "x-ms-version", BSC.pack $ apiVersion request)
                               , (CI.mk $ BSC.pack "content-type", BSC.pack "application/xml")
                               ]
        }
      Response _ _ _ lbs <- httpLbs req' manager 
      liftIO . runX $ readString [withValidate no] (BSLC.unpack lbs) >>> parser request
