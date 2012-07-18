import Prelude hiding (catch)
import System.Environment (getArgs)
import System.IO (IOMode(ReadWriteMode), hClose)
import Data.IORef (IORef, writeIORef, readIORef, newIORef)
import qualified Data.ByteString.Lazy.Char8 as BSLC (pack, putStrLn)
import Control.Exception (SomeException, catch)
import qualified Crypto.Random.AESCtr as RNG (makeSystem)
import Network.Azure.ServiceManagement
  ( fileReadCertificate
  , fileReadPrivateKey
  )
import Network.Socket 
  ( socket
  , Family(AF_INET)
  , SocketType(Stream)
  , defaultProtocol
  , SockAddr(SockAddrInet)
  , connect
  , sClose
  , socketToHandle
  , HostName
  , PortNumber
  )
import Network.BSD (getHostByName, hostAddresses)
import Network.TLS 
  ( contextNewOnHandle
  , Params
  , Context
  , defaultLogging
  , loggingPacketSent
  , loggingPacketRecv
  , onCertificateRequest
  , onCertificatesRecv
  , pLogging
  , pCertificates
  , pCiphers
  , pConnectVersion
  , pAllowedVersions
  , setSessionManager
  , defaultParamsClient
  , updateClientParams
  , clientWantSessionResume
  , Version(TLS10, TLS11, TLS12)
  , SessionManager(sessionEstablish, sessionResume, sessionInvalidate)
  , SessionID
  , SessionData
  , PrivateKey
  , handshake
  , sendData
  , recvData'
  , bye
  )
import Network.TLS.Extra
  ( certificateVerifyChain
  , ciphersuite_all
  )
import Data.Certificate.X509 (X509)

main :: IO ()
main = do
  [subscriptionId, pathToCert, pathToKey] <- getArgs
  cert <- fileReadCertificate pathToCert
  key  <- fileReadPrivateKey pathToKey
  sessionState <- newIORef undefined
  let hostname = "management.core.windows.net"
  let port     = 443 
  runTLS (getDefaultParams sessionState [(cert, Just key)]) hostname port $ \ctx -> do
    handshake ctx
    sendData ctx $ BSLC.pack $ concat 
      [ "GET /" ++ subscriptionId ++ "/services/hostedservices HTTP/1.1\r\n"
      , "host: " ++ hostname ++ "\r\n" 
      , "content-type: application/xml\r\n"
      , "x-ms-version: 2010-10-28\r\n"
      , "\r\n"
      ]
    d <- recvData' ctx
    bye ctx
    BSLC.putStrLn d

--------------------------------------------------------------------------------
-- Taken from tls-debug/src/SimpleClient.hs                                   --
--------------------------------------------------------------------------------

runTLS :: Params -> HostName -> PortNumber -> (Context -> IO a) -> IO ()
runTLS params hostname portNumber f = do
  rng  <- RNG.makeSystem
  he   <- getHostByName hostname
  sock <- socket AF_INET Stream defaultProtocol
  let sockaddr = SockAddrInet portNumber (head $ hostAddresses he)
  catch (connect sock sockaddr)
        (\(e :: SomeException) -> sClose sock >> error ("cannot open socket " ++ show sockaddr ++ " " ++ show e))
  dsth <- socketToHandle sock ReadWriteMode
  ctx <- contextNewOnHandle dsth params rng
  _ <- f ctx
  hClose dsth

getDefaultParams :: IORef (SessionID, SessionData) 
                 -> [(X509, Maybe PrivateKey)] 
                 -> Params 
getDefaultParams sessionState certs = 
    updateClientParams setCParams $ setSessionManager (SessionRef sessionState) $ defaultParamsClient
      { pConnectVersion    = TLS10
      , pAllowedVersions   = [TLS10,TLS11,TLS12]
      , pCiphers           = ciphersuite_all 
      , pCertificates      = certs
      , pLogging           = logging
      , onCertificatesRecv = crecv
      }
  where
    setCParams cparams = cparams { clientWantSessionResume = Nothing 
                                 , onCertificateRequest    = creq 
                                 }
    logging = defaultLogging
      { loggingPacketSent = putStrLn . ("debug: >> " ++)
      , loggingPacketRecv = putStrLn . ("debug: << " ++)
      }
    crecv = certificateVerifyChain 
    creq _ = return certs

data SessionRef = SessionRef (IORef (SessionID, SessionData))

instance SessionManager SessionRef where
  sessionEstablish (SessionRef ref) sid sdata = 
    writeIORef ref (sid,sdata)
  sessionResume (SessionRef ref) sid = do
    (s, d) <- readIORef ref
    if s == sid then return (Just d) else return Nothing
  sessionInvalidate _ _ = 
    return ()
