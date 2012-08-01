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
import Control.Category (id, (.))
import Control.Arrow (arr)
import Control.Monad (forM)
import Data.Maybe (listToMaybe)
import Data.ByteString.Char8 as BSC (pack)
import Data.ByteString.Lazy.Char8 as BSLC (unpack)
import Network.TLS (PrivateKey)
import Network.TLS.Extra (fileReadCertificate, fileReadPrivateKey)
import Data.Certificate.X509 (X509)
import Control.Monad.Trans.Resource (ResourceT)
import Control.Monad.IO.Class (liftIO)
import Control.Arrow.ArrowList (listA, arr2A)
import Text.PrettyPrint 
  ( Doc
  , text
  , (<+>)
  , ($$)
  , vcat
  , hang
  , doubleQuotes
  )
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
--  , writeDocumentToString
--  , withIndent
--  , yes
  )
-- import Control.Arrow.ArrowIO (arrIO)
import Text.XML.HXT.XPath (getXPathTrees)

--------------------------------------------------------------------------------
-- Data types                                                                 --
--------------------------------------------------------------------------------

data HostedService = HostedService { 
    hostedServiceName :: String 
  }

data CloudService = CloudService {
    cloudServiceName :: String 
  , cloudServiceVMs  :: [VirtualMachine]
  }

data VirtualMachine = VirtualMachine { 
    vmName           :: String
  , vmIpAddress      :: String
  , vmInputEndpoints :: [Endpoint]
  }

data Endpoint = Endpoint {
    endpointName :: String
  , endpointPort :: String 
  , endpointVip  :: String
  }

--------------------------------------------------------------------------------
-- Pretty-printing                                                            --
--------------------------------------------------------------------------------

instance Show HostedService where 
  show = show . ppHostedService

instance Show CloudService where
  show = show . ppCloudService

instance Show VirtualMachine where
  show = show . ppVirtualMachine

instance Show Endpoint where
  show = show . ppEndpoint

ppHostedService :: HostedService -> Doc
ppHostedService = text . hostedServiceName

ppCloudService :: CloudService -> Doc
ppCloudService cs =
    (text "Cloud Service" <+> (doubleQuotes . text . cloudServiceName $ cs)) 
  `hang2`
    (   text "VIRTUAL MACHINES"
      `hang2`
        (vcat . map ppVirtualMachine . cloudServiceVMs $ cs)
    )

ppVirtualMachine :: VirtualMachine -> Doc
ppVirtualMachine vm = 
    (text "Virtual Machine" <+> (doubleQuotes . text . vmName $ vm))
  `hang2`
    (    text "IP" <+> text (vmIpAddress vm)
      $$ (    text "INPUT ENDPOINTS"
           `hang2`
              (vcat . map ppEndpoint . vmInputEndpoints $ vm)
         )
    )

ppEndpoint :: Endpoint -> Doc
ppEndpoint ep = 
    (text "Input endpoint" <+> (doubleQuotes . text . endpointName $ ep))
  `hang2`
    (    text "Port" <+> text (endpointPort ep)
      $$ text "VIP"  <+> text (endpointVip ep)
    )

hang2 :: Doc -> Doc -> Doc
hang2 d1 = hang d1 2

--------------------------------------------------------------------------------
-- Pure operations                                                            --
--------------------------------------------------------------------------------

vmSshEndpoint :: VirtualMachine -> Maybe Endpoint
vmSshEndpoint vm = listToMaybe 
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
          roleInst  <- arr2A getXPathTrees -< ("//RoleInstance[RoleName='" ++ name ++ "']", xml)
          ip        <- getText . getXPathTrees "/RoleInstance/IpAddress/text()" -< roleInst
          endpoints <- listA (parseEndpoint . getXPathTrees "//InputEndpoint") -< role
          id -< VirtualMachine name ip endpoints
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
      liftIO . runX $ proc _ -> do
        xml <- readString [withValidate no] (BSLC.unpack lbs) -< ()
        -- arrIO putStrLn . writeDocumentToString [withIndent yes] -< xml
        parser request -< xml
