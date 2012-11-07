{-# LANGUAGE Arrows #-}
module Network.Azure.ServiceManagement 
  ( -- * Data types
    CloudService
  , cloudServiceName
  , cloudServiceVMs
  , VirtualMachine
  , vmName
  , vmIpAddress
  , vmInputEndpoints
  , Endpoint
  , endpointName
  , endpointPort
  , endpointVip
    -- * Pure functions
  , vmSshEndpoint 
    -- * Setup
  , AzureSetup(..)
  , azureSetup
    -- * High-level API
  , cloudServices 
  ) where

import Prelude hiding (id, (.))
import Control.Category (id, (.))
import Control.Arrow (arr)
import Control.Monad (forM)
import Control.Applicative ((<$>), (<*>))
import Data.Maybe (listToMaybe)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Char8 as BSC (pack)
import Data.ByteString.Lazy.Char8 as BSLC (unpack)
import Data.Binary (Binary(get,put))
import Data.Binary.Put (runPut)
import Data.Binary.Get (Get, runGet)
import Network.TLS (PrivateKey(PrivRSA))
import Network.TLS.Extra (fileReadCertificate, fileReadPrivateKey)
import Data.Certificate.X509 (X509, encodeCertificate, decodeCertificate)
import qualified Crypto.Types.PubKey.RSA as RSA (PrivateKey(..))
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
  )
import Text.XML.HXT.XPath (getXPathTrees)

--------------------------------------------------------------------------------
-- Data types                                                                 --
--------------------------------------------------------------------------------

data HostedService = HostedService { 
    hostedServiceName :: String 
  }

-- | A cloud service is a bunch of virtual machines that are part of the same
-- network (i.e., can talk to each other directly using standard TCP 
-- connections).
data CloudService = CloudService {
    -- | Name of the service.
    cloudServiceName :: String 
    -- | Virtual machines that are part of this cloud service.
  , cloudServiceVMs  :: [VirtualMachine]
  }

-- | Virtual machine
data VirtualMachine = VirtualMachine { 
    -- | Name of the virtual machine.
    vmName           :: String
    -- | The /internal/ IP address of the virtual machine (that is, the 
    -- IP address on the Cloud Service). For the globally accessible IP
    -- address see 'vmInputEndpoints'.
  , vmIpAddress      :: String
    -- | Globally accessible endpoints to the virtual machine
  , vmInputEndpoints :: [Endpoint]
  }

-- | Globally accessible endpoint for a virtual machine
data Endpoint = Endpoint {
    -- | Name of the endpoint (typical example: @SSH@)
    endpointName :: String
    -- | Port number (typical examples are 22 or high numbered ports such as 53749) 
  , endpointPort :: String 
    -- | Virtual IP address (that is, globally accessible IP address).
    --
    -- This corresponds to the IP address associated with the Cloud Service
    -- (i.e., that would be returned by a DNS lookup for @name.cloudapp.net@, 
    -- where @name@ is the name of the Cloud Service).
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

-- | Find the endpoint with name @SSH@.
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
--
-- The documentation of "distributed-process-azure" explains in detail how
-- to obtain the SSL client certificate and the private key for your Azure
-- account.
--
-- See also 'azureSetup'.
data AzureSetup = AzureSetup
  { -- | Azure subscription ID
    subscriptionId :: String
    -- | SSL client certificate
  , certificate :: X509
    -- | RSA private key
  , privateKey :: PrivateKey
    -- | Base URL (generally <https://management.core.windows.net>)
  , baseUrl :: String
  }

-- TODO: it's dubious to be transferring private keys, but we transfer them
-- over a secure connection and it can be argued that it's safer than actually
-- storing the private key on each remote server 

encodePrivateKey :: PrivateKey -> ByteString
encodePrivateKey (PrivRSA pkey) = runPut $ do
  put (RSA.private_size pkey)
  put (RSA.private_n pkey)
  put (RSA.private_d pkey)
  put (RSA.private_p pkey)
  put (RSA.private_q pkey)
  put (RSA.private_dP pkey)
  put (RSA.private_dQ pkey)
  put (RSA.private_qinv pkey)

decodePrivateKey :: ByteString -> PrivateKey
decodePrivateKey = PrivRSA . runGet getPrivateKey 
  where
    getPrivateKey :: Get RSA.PrivateKey
    getPrivateKey = 
      RSA.PrivateKey <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get

instance Binary AzureSetup where
  put (AzureSetup sid cert pkey url) = do
    put sid
    put (encodeCertificate cert)
    put (encodePrivateKey pkey)
    put url 
  get = do
    sid  <- get
    Right cert <- decodeCertificate <$> get
    pkey <- decodePrivateKey <$> get
    url  <- get
    return $ AzureSetup sid cert pkey url

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

-- | Find available cloud services 
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
