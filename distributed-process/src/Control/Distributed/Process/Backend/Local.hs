-- | Simple backend based on the TCP transport which offers node discovery
-- based on UDP multicast
module Control.Distributed.Process.Backend.Local 
  ( LocalBackend(..)
  , initializeBackend
  ) where

import Data.Binary (encode)
import qualified Data.ByteString as BSS (concat, append)
import qualified Data.ByteString.Lazy as BSL (toChunks, length) 
import Control.Applicative ((<$>))
import Control.Exception (throw)
import Control.Monad (forM_)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, readMVar)
import Control.Distributed.Process.Internal.Types 
  ( LocalNode
  , RemoteTable
  , NodeId
  )
import qualified Control.Distributed.Process.Node as Node 
  ( newLocalNode
  , localNodeId
  )
import qualified Network.Transport.TCP as NT 
  ( createTransport
  , defaultTCPParameters
  )
import Network.Transport.Internal (encodeInt32, decodeInt32)
import qualified Network.Transport as NT ()
import qualified Network.Socket as N (HostName, ServiceName, Socket, SockAddr)
import qualified Network.Socket.ByteString as NBS (recvFrom, sendTo)
import qualified Network.Multicast as NM (multicastSender, multicastReceiver)

data LocalBackend = LocalBackend {
    newLocalNode :: IO LocalNode
  , findPeers    :: IO [NodeId]
  }

data LocalBackendState = LocalBackendState {
   localNodes :: [LocalNode]
 }

-- | Initialize the backend
initializeBackend :: N.HostName -> N.ServiceName -> RemoteTable -> IO LocalBackend
initializeBackend host port rtable = do
  mTransport    <- NT.createTransport host port NT.defaultTCPParameters 
  mcastSender   <- NM.multicastSender "224.0.0.99" 9999
  mcastReceiver <- NM.multicastReceiver "224.0.0.99" 9999
  backendState  <- newMVar LocalBackendState { localNodes = [] }
  forkIO $ peerDiscoveryDaemon backendState mcastReceiver mcastSender
  case mTransport of
    Left err -> throw err
    Right transport -> return LocalBackend {
        newLocalNode = Node.newLocalNode transport rtable 
      , findPeers    = apiFindPeers mcastSender
      }

-- | Peer discovery
apiFindPeers :: (N.Socket, N.SockAddr) -> IO [NodeId]
apiFindPeers (sock, addr) = do
  NBS.sendTo sock (encodeInt32 (0xCDAECDAE :: Int)) addr 
  return []

-- | Respond to peer discovery requests sent by other nodes
peerDiscoveryDaemon :: MVar LocalBackendState 
                    -> N.Socket 
                    -> (N.Socket, N.SockAddr) 
                    -> IO ()
peerDiscoveryDaemon backendState readSock (writeSock, addr) = do
  (msgLen, _remoteAddr) <- NBS.recvFrom readSock 4

  case decodeInt32 msgLen of
    (0xCDAECDAE :: Int) -> do
      nodes <- localNodes <$> readMVar backendState
      forM_ nodes $ \node -> do
        let nodeAddr = encode (Node.localNodeId node)
            msg      = encodeInt32 (BSL.length nodeAddr) `BSS.append`
                       (BSS.concat . BSL.toChunks $ nodeAddr) 
        NBS.sendTo writeSock msg addr
