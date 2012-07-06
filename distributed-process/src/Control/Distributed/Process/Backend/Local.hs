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
-- > import Control.Distributed.Process.Backend.Local 
-- > 
-- > master :: LocalBackend -> [NodeId] -> Process ()
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
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Backend.Local 
  ( -- * Initialization 
    LocalBackend(..)
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
import Control.Monad (forever, forM)
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
  , registerRemote
  , getSelfPid
  , register
  , expect
  , nsendRemote
  , receiveWait
  , matchIf
  , processNodeId
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
import Control.Distributed.Process.Internal.Multicast (initMulticast)

-- | Local backend 
data LocalBackend = LocalBackend {
    -- | Create a new local node
    newLocalNode :: IO Node.LocalNode
    -- | @findPeers t@ sends out a /who's there?/ request, waits 't' msec,
    -- and then collects and returns the answers
  , findPeers :: Int -> IO [NodeId]
    -- | Make sure that all log messages are printed by the logger on the
    -- current node
  , redirectLogsHere :: Process ()
  }

data LocalBackendState = LocalBackendState {
   _localNodes      :: [Node.LocalNode]
 , _peers           :: Set NodeId
 ,  discoveryDaemon :: ThreadId
 }

-- | Initialize the backend
initializeBackend :: N.HostName -> N.ServiceName -> RemoteTable -> IO LocalBackend
initializeBackend host port rtable = do
  mTransport   <- NT.createTransport host port NT.defaultTCPParameters 
  (recv, send) <- initMulticast  "224.0.0.99" 9999 1024
  (_, backendState) <- fixIO $ \ ~(tid, _) -> do
    backendState <- newMVar LocalBackendState 
                      { _localNodes      = [] 
                      , _peers           = Set.empty
                      ,  discoveryDaemon = tid
                      }
    tid' <- forkIO $ peerDiscoveryDaemon backendState recv send 
    return (tid', backendState)
  case mTransport of
    Left err -> throw err
    Right transport -> 
      let backend = LocalBackend {
          newLocalNode       = apiNewLocalNode transport rtable backendState 
        , findPeers          = apiFindPeers send backendState
        , redirectLogsHere   = apiRedirectLogsHere backend 
        }
      in return backend

-- | Create a new local node
apiNewLocalNode :: NT.Transport 
                -> RemoteTable 
                -> MVar LocalBackendState
                -> IO Node.LocalNode
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
startSlave :: LocalBackend -> IO ()
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
findSlaves :: LocalBackend -> Process [NodeId]
findSlaves backend = do
  nodes <- liftIO $ findPeers backend 1000000   
  -- Fire of asynchronous requests for the slave controller
  forM_ nodes $ \nid -> whereisRemoteAsync nid "slaveController" 
  -- Wait for the replies
  catMaybes <$> forM nodes (\_ -> 
    receiveWait 
      [ matchIf (\(WhereIsReply label _) -> label == "slaveController")
                (\(WhereIsReply _ mPid) -> return (processNodeId <$> mPid))
      ])

-- | Terminate all slaves
terminateAllSlaves :: LocalBackend -> Process ()
terminateAllSlaves backend = do
  slaves <- findSlaves backend
  forM_ slaves terminateSlave
  liftIO $ threadDelay 1000000

--------------------------------------------------------------------------------
-- Master nodes
--------------------------------------------------------------------------------

-- | 'startMaster' finds all slaves currently available on the local network
-- (which should therefore be started first), redirects all log messages to
-- itself, and then calls the specified process, passing the list of slaves
-- nodes. 
--
-- Terminates when the specified process terminates. If you want to terminate
-- the slaves when the master terminates, you should manually call 
-- 'terminateAllSlaves'.
startMaster :: LocalBackend -> ([NodeId] -> Process ()) -> IO ()
startMaster backend proc = do
  node <- newLocalNode backend
  Node.runProcess node $ do
    slaves <- findSlaves backend
    redirectLogsHere backend
    proc slaves

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localNodes :: Accessor LocalBackendState [Node.LocalNode]
localNodes = accessor _localNodes (\ns st -> st { _localNodes = ns })

peers :: Accessor LocalBackendState (Set NodeId)
peers = accessor _peers (\ps st -> st { _peers = ps })
