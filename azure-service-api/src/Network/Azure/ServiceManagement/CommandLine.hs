-- Base
import Prelude hiding (catch)
import System.Environment (getArgs, getEnv)
import System.IO (IOMode(ReadWriteMode), hClose)
import System.FilePath ((</>), takeFileName)
import Data.IORef (IORef, writeIORef, readIORef, newIORef)
import qualified Data.ByteString.Lazy.Char8 as BSLC (pack, putStrLn)
import Control.Exception (SomeException, catch)

-- SSL
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

-- SSH
import Network.SSH.Client.LibSSH2 
  ( withSSH2
  , scpReceiveFile
  , scpSendFile
  , checkHost
  , withSession
  , readAllChannel
  )
import Network.SSH.Client.LibSSH2.Foreign 
  ( initialize
  , exit
  , publicKeyAuthFile
  , channelExecute
  )
import Codec.Binary.UTF8.String (decodeString)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["azure", subscriptionId, pathToCert, pathToKey] ->
      tryConnectToAzure subscriptionId pathToCert pathToKey
    ["command", user, host, port, cmd] -> 
      runCommand user host (read port) cmd
    ["send", user, host, port, path] -> 
      sendFile user host (read port) path
    ["receive", user, host, port, path] -> 
      receiveFile user host (read port) path
    _ ->
      putStrLn "Invalid command line arguments"

--------------------------------------------------------------------------------
-- Taken from libssh2/ssh-client                                              --
--------------------------------------------------------------------------------

runCommand login host port command =
  ssh login host port $ \ch -> do
      channelExecute ch command
      result <- readAllChannel ch
      let r = decodeString result
      print (length result)
      print (length r)
      putStrLn r

sendFile login host port path = do
  initialize True
  home <- getEnv "HOME"
  let known_hosts = home </> ".ssh" </> "known_hosts"
      public = home </> ".ssh" </> "id_rsa.pub"
      private = home </> ".ssh" </> "id_rsa"

  withSession host port $ \_ s -> do
      r <- checkHost s host port known_hosts
      print r
      publicKeyAuthFile s login public private ""
      sz <- scpSendFile s 0o644 path (takeFileName path)
      putStrLn $ "Sent: " ++ show sz ++ " bytes."
  exit

receiveFile login host port path = do
  initialize True
  home <- getEnv "HOME"
  let known_hosts = home </> ".ssh" </> "known_hosts"
      public = home </> ".ssh" </> "id_rsa.pub"
      private = home </> ".ssh" </> "id_rsa"

  withSession host port $ \_ s -> do
      r <- checkHost s host port known_hosts
      print r
      publicKeyAuthFile s login public private ""
      sz <- scpReceiveFile s (takeFileName path) path
      putStrLn $ "Received: " ++ show sz ++ " bytes."
  exit

ssh login host port actions = do
  initialize True
  home <- getEnv "HOME"
  let known_hosts = home </> ".ssh" </> "known_hosts"
      public = home </> ".ssh" </> "id_rsa.pub"
      private = home </> ".ssh" </> "id_rsa"
  withSSH2 known_hosts public private login host port $ actions
  exit

--------------------------------------------------------------------------------
-- Taken from tls-debug/src/SimpleClient.hs                                   --
--------------------------------------------------------------------------------

tryConnectToAzure :: String -> String -> String -> IO ()
tryConnectToAzure subscriptionId pathToCert pathToKey = do
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
