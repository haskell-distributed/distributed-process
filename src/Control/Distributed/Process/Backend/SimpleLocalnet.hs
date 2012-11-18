-- | Simple backend based on the TCP transport which offers node discovery
-- based on UDP multicast. This is a zero-configuration backend designed to
-- get you going with Cloud Haskell quickly without imposing any structure
-- on your application.
--
-- To simplify getting started we provide special support for /master/ and 
-- /slave/ nodes (see 'startSlave' and 'startMaster'). Use of these functions
-- is completely optional; you can use the local backend without making use
-- of the predefined master and slave nodes.
-- 
-- [Minimal example]
--
-- > import System.Environment (getArgs)
-- > import Control.Distributed.Process
-- > import Control.Distributed.Process.Node (initRemoteTable)
-- > import Control.Distributed.Process.Backend.SimpleLocalnet
-- > 
-- > master :: Backend -> [NodeId] -> Process ()
-- > master backend slaves = do
-- >   -- Do something interesting with the slaves
-- >   liftIO . putStrLn $ "Slaves: " ++ show slaves
-- >   -- Terminate the slaves when the master terminates (this is optional)
-- >   terminateAllSlaves backend
-- > 
-- > main :: IO ()
-- > main = do
-- >   args <- getArgs
-- > 
-- >   case args of
-- >     ["master", host, port] -> do
-- >       backend <- initializeBackend host port initRemoteTable 
-- >       startMaster backend (master backend)
-- >     ["slave", host, port] -> do
-- >       backend <- initializeBackend host port initRemoteTable 
-- >       startSlave backend
-- 
-- [Compiling and Running]
--
-- Save to @example.hs@ and compile using
-- 
-- > ghc -threaded example.hs
--
-- Fire up some slave nodes (for the example, we run them on a single machine):
--
-- > ./example slave localhost 8080 &
-- > ./example slave localhost 8081 &
-- > ./example slave localhost 8082 &
-- > ./example slave localhost 8083 &
--
-- And start the master node:
--
-- > ./example master localhost 8084
--
-- which should then output:
--
-- > Slaves: [nid://localhost:8083:0,nid://localhost:8082:0,nid://localhost:8081:0,nid://localhost:8080:0]
--
-- at which point the slaves should exit.
--
-- To run the example on multiple machines, you could run
--
-- > ./example slave 198.51.100.1 8080 &
-- > ./example slave 198.51.100.2 8080 &
-- > ./example slave 198.51.100.3 8080 &
-- > ./example slave 198.51.100.4 8080 &
--
-- on four different machines (with IP addresses 198.51.100.1..4), and run the
-- master on a fifth node (or on any of the four machines that run the slave
-- nodes).
--
-- It is important that every node has a unique (hostname, port number) pair, 
-- and that the hostname you use to initialize the node can be resolved by
-- peer nodes. In other words, if you start a node and pass hostname @localhost@
-- then peer nodes won't be able to reach it because @localhost@ will resolve
-- to a different IP address for them.
--
-- [Troubleshooting]
--
-- If you try the above example and the master process cannot find any slaves,
-- then it might be that your firewall settings do not allow for UDP multicast
-- (in particular, the default iptables on some Linux distributions might not
-- allow it).  
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Backend.SimpleLocalnet
  ( -- * Initialization 
    Backend(..)
  , initializeBackend
    -- * Slave nodes
  , startSlave
  , terminateSlave
  , findSlaves
  , terminateAllSlaves
    -- * Master nodes
  , startMaster
  ) where

import System.IO (fixIO)
import Data.Maybe (catMaybes)
import Data.Binary (Binary(get, put), getWord8, putWord8)
import Data.Accessor (Accessor, accessor, (^:), (^.))
import Data.Set (Set)
import qualified Data.Set as Set (insert, empty, toList)
import Data.Foldable (forM_)
import Data.Typeable (Typeable)
import Control.Applicative ((<$>))
import Control.Exception (throw)
import Control.Monad (forever, forM, replicateM)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (forkIO, threadDelay, ThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Distributed.Process
  ( RemoteTable
  , NodeId
  , Process
  , WhereIsReply(..)
  , whereis
  , whereisRemoteAsync
  , reregisterRemoteAsync
  , getSelfPid
  , register
  , expect
  , nsendRemote
  , receiveWait
  , match
  , matchIf
  , processNodeId
  , monitorNode
  , unmonitor
  , NodeMonitorNotification(..)
  )
import qualified Control.Distributed.Process.Node as Node 
  ( LocalNode
  , newLocalNode
  , localNodeId
  , runProcess
  )
import qualified Network.Transport.TCP as NT 
  ( createTransport
  , defaultTCPParameters
  )
import qualified Network.Transport as NT (Transport)
import qualified Network.Socket as N (HostName, ServiceName, SockAddr)
import Control.Distributed.Process.Backend.SimpleLocalnet.Internal.Multicast (initMulticast)

-- | Local backend 
data Backend = Backend {
    -- | Create a new local node
    newLocalNode :: IO Node.LocalNode
    -- | @findPeers t@ broadcasts a /who's there?/ message on the local
    -- network, waits 't' msec, and then collects and returns the answers.
    -- You can use this to dynamically discover peer nodes.
  , findPeers :: Int -> IO [NodeId]
    -- | Make sure that all log messages are printed by the logger on the
    -- current node
  , redirectLogsHere :: Process ()
  }

data BackendState = BackendState {
   _localNodes      :: [Node.LocalNode]
 , _peers           :: Set NodeId
 ,  discoveryDaemon :: ThreadId
 }

-- | Initialize the backend
initializeBackend :: N.HostName -> N.ServiceName -> RemoteTable -> IO Backend
initializeBackend host port rtable = do
  mTransport   <- NT.createTransport host port NT.defaultTCPParameters 
  (recv, send) <- initMulticast  "224.0.0.99" 9999 1024
  (_, backendState) <- fixIO $ \ ~(tid, _) -> do
    backendState <- newMVar BackendState 
                      { _localNodes      = [] 
                      , _peers           = Set.empty
                      ,  discoveryDaemon = tid
                      }
    tid' <- forkIO $ peerDiscoveryDaemon backendState recv send 
    return (tid', backendState)
  case mTransport of
    Left err -> throw err
    Right transport -> 
      let backend = Backend {
          newLocalNode       = apiNewLocalNode transport rtable backendState 
        , findPeers          = apiFindPeers send backendState
        , redirectLogsHere   = apiRedirectLogsHere backend 
        }
      in return backend

-- | Create a new local node
apiNewLocalNode :: NT.Transport 
                -> RemoteTable 
                -> MVar BackendState
                -> IO Node.LocalNode
apiNewLocalNode transport rtable backendState = do
  localNode <- Node.newLocalNode transport rtable 
  modifyMVar_ backendState $ return . (localNodes ^: (localNode :))
  return localNode

-- | Peer discovery
apiFindPeers :: (PeerDiscoveryMsg -> IO ()) 
             -> MVar BackendState 
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
peerDiscoveryDaemon :: MVar BackendState 
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
apiRedirectLogsHere :: Backend -> Process ()
apiRedirectLogsHere backend = do
  mLogger <- whereis "logger"
  forM_ mLogger $ \logger -> do
    nids <- liftIO $ findPeers backend 1000000 
    forM_ nids $ \nid -> reregisterRemoteAsync nid "logger" logger -- ignore async response

--------------------------------------------------------------------------------
-- Slaves                                                                     --
--------------------------------------------------------------------------------

-- | Messages to slave nodes
--
-- This datatype is not exposed; instead, we expose primitives for dealing
-- with slaves.
data SlaveControllerMsg = 
    SlaveTerminate
  deriving (Typeable, Show)

instance Binary SlaveControllerMsg where
  put SlaveTerminate = putWord8 0 
  get = do
    header <- getWord8
    case header of
      0 -> return SlaveTerminate
      _ -> fail "SlaveControllerMsg.get: invalid"

-- | Calling 'slave' sets up a new local node and then waits. You start
-- processes on the slave by calling 'spawn' from other nodes.
--
-- This function does not return. The only way to exit the slave is to CTRL-C
-- the process or call terminateSlave from another node.
startSlave :: Backend -> IO ()
startSlave backend = do
  node <- newLocalNode backend 
  Node.runProcess node slaveController 

-- | The slave controller interprets 'SlaveControllerMsg's
slaveController :: Process ()
slaveController = do
    pid <- getSelfPid
    register "slaveController" pid
    go
  where
    go = do
      msg <- expect
      case msg of
        SlaveTerminate -> return ()

-- | Terminate the slave at the given node ID
terminateSlave :: NodeId -> Process ()
terminateSlave nid = nsendRemote nid "slaveController" SlaveTerminate

-- | Find slave nodes
findSlaves :: Backend -> Process [NodeId]
findSlaves backend = do
  nodes <- liftIO $ findPeers backend 1000000   
  -- Fire of asynchronous requests for the slave controller
  refs <- forM nodes $ \nid -> do
    whereisRemoteAsync nid "slaveController" 
    ref <- monitorNode nid
    return (nid, ref)
  -- Wait for the replies
  catMaybes <$> replicateM (length nodes) ( 
    receiveWait 
      [ matchIf (\(WhereIsReply label _) -> label == "slaveController")
                (\(WhereIsReply _ mPid) -> 
                  case mPid of
                    Nothing -> 
                      return Nothing
                    Just pid -> do
                      let nid      = processNodeId pid
                          Just ref = lookup nid refs
                      unmonitor ref 
                      return (Just nid))
      , match (\(NodeMonitorNotification {}) -> return Nothing) 
      ])

-- | Terminate all slaves
terminateAllSlaves :: Backend -> Process ()
terminateAllSlaves backend = do
  slaves <- findSlaves backend
  forM_ slaves terminateSlave
  liftIO $ threadDelay 1000000

--------------------------------------------------------------------------------
-- Master nodes
--------------------------------------------------------------------------------

-- | 'startMaster' finds all slaves /currently/ available on the local network,
-- redirects all log messages to itself, and then calls the specified process,
-- passing the list of slaves nodes. 
--
-- Terminates when the specified process terminates. If you want to terminate
-- the slaves when the master terminates, you should manually call 
-- 'terminateAllSlaves'.
--
-- If you start more slave nodes after having started the master node, you can
-- discover them with later calls to 'findSlaves', but be aware that you will
-- need to call 'redirectLogHere' to redirect their logs to the master node.  
--
-- Note that you can use functionality of "SimpleLocalnet" directly (through
-- 'Backend'), instead of using 'startMaster'/'startSlave', if the master/slave
-- distinction does not suit your application.
startMaster :: Backend -> ([NodeId] -> Process ()) -> IO ()
startMaster backend proc = do
  node <- newLocalNode backend
  Node.runProcess node $ do
    slaves <- findSlaves backend
    redirectLogsHere backend
    proc slaves

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localNodes :: Accessor BackendState [Node.LocalNode]
localNodes = accessor _localNodes (\ns st -> st { _localNodes = ns })

peers :: Accessor BackendState (Set NodeId)
peers = accessor _peers (\ps st -> st { _peers = ps })
