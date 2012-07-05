-- | Simple backend based on the TCP transport which offers node discovery
-- based on UDP multicast
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Backend.Local 
  ( LocalBackend(..)
  , initializeBackend
  ) where

import Data.Binary (Binary(get, put), getWord8, putWord8)
import Data.Accessor (Accessor, accessor, (^:), (^.))
import Data.Set (Set)
import qualified Data.Set as Set (insert, empty, toList)
import Data.Foldable (forM_)
import Control.Applicative ((<$>))
import Control.Exception (throw)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Distributed.Process.Internal.Types 
  ( LocalNode
  , RemoteTable
  , NodeId
  , Process
  )
import qualified Control.Distributed.Process.Node as Node 
  ( newLocalNode
  , localNodeId
  )
import qualified Network.Transport.TCP as NT 
  ( createTransport
  , defaultTCPParameters
  )
import qualified Network.Transport as NT (Transport)
import qualified Network.Socket as N (HostName, ServiceName, SockAddr)
import Control.Distributed.Process.Internal.Multicast (initMulticast)
import Control.Distributed.Process.Internal.Primitives (whereis, registerRemote)

-- | Local backend 
data LocalBackend = LocalBackend {
    -- | Create a new local node
    newLocalNode :: IO LocalNode
    -- | @findPeers t@ sends out a /who's there?/ request, waits 't' msec,
    -- and then collects and returns the answers
  , findPeers :: Int -> IO [NodeId]
    -- | Make sure that all log messages are printed by the logger on the
    -- current node
  , redirectLogsHere :: Process ()
  }

data LocalBackendState = LocalBackendState {
   _localNodes :: [LocalNode]
 , _peers      :: Set NodeId
 }

-- | Initialize the backend
initializeBackend :: N.HostName -> N.ServiceName -> RemoteTable -> IO LocalBackend
initializeBackend host port rtable = do
  mTransport   <- NT.createTransport host port NT.defaultTCPParameters 
  (recv, send) <- initMulticast  "224.0.0.99" 9999 1024
  backendState <- newMVar LocalBackendState 
                    { _localNodes = [] 
                    , _peers      = Set.empty
                    }
  forkIO $ peerDiscoveryDaemon backendState recv send 
  case mTransport of
    Left err -> throw err
    Right transport -> 
      let backend = LocalBackend {
          newLocalNode     = apiNewLocalNode transport rtable backendState 
        , findPeers        = apiFindPeers send backendState
        , redirectLogsHere = apiRedirectLogsHere backend 
        }
      in return backend

-- | Create a new local node
apiNewLocalNode :: NT.Transport 
                -> RemoteTable 
                -> MVar LocalBackendState
                -> IO LocalNode
apiNewLocalNode transport rtable backendState = do
  localNode <- Node.newLocalNode transport rtable 
  modifyMVar_ backendState $ return . (localNodes ^: (localNode :))
  return localNode

-- | Peer discovery
apiFindPeers :: (PeerDiscoveryMsg -> IO ()) 
             -> MVar LocalBackendState 
             -> Int
             -> IO [NodeId]
apiFindPeers send backendState delay = do
  send PeerDiscoveryRequest 
  threadDelay delay 
  Set.toList . (^. peers) <$> readMVar backendState  

data PeerDiscoveryMsg = 
    PeerDiscoveryRequest 
  | PeerDiscoveryReply NodeId

instance Binary PeerDiscoveryMsg where
  put PeerDiscoveryRequest     = putWord8 0
  put (PeerDiscoveryReply nid) = putWord8 1 >> put nid
  get = do
    header <- getWord8 
    case header of
      0 -> return PeerDiscoveryRequest
      1 -> PeerDiscoveryReply <$> get
      _ -> fail "PeerDiscoveryMsg.get: invalid"

-- | Respond to peer discovery requests sent by other nodes
peerDiscoveryDaemon :: MVar LocalBackendState 
                    -> IO (PeerDiscoveryMsg, N.SockAddr)
                    -> (PeerDiscoveryMsg -> IO ()) 
                    -> IO ()
peerDiscoveryDaemon backendState recv send = forever go
  where
    go = do
      (msg, _) <- recv
      case msg of
        PeerDiscoveryRequest -> do
          nodes <- (^. localNodes) <$> readMVar backendState
          forM_ nodes $ send . PeerDiscoveryReply . Node.localNodeId 
        PeerDiscoveryReply nid ->
          modifyMVar_ backendState $ return . (peers ^: Set.insert nid)

--------------------------------------------------------------------------------
-- Back-end specific primitives                                               --
--------------------------------------------------------------------------------

-- | Make sure that all log messages are printed by the logger on this node
apiRedirectLogsHere :: LocalBackend -> Process ()
apiRedirectLogsHere backend = do
  mLogger <- whereis "logger"
  forM_ mLogger $ \logger -> do
    nids <- liftIO $ findPeers backend 1000000 
    forM_ nids $ \nid -> registerRemote nid "logger" logger

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localNodes :: Accessor LocalBackendState [LocalNode]
localNodes = accessor _localNodes (\ns st -> st { _localNodes = ns })

peers :: Accessor LocalBackendState (Set NodeId)
peers = accessor _peers (\ps st -> st { _peers = ps })
