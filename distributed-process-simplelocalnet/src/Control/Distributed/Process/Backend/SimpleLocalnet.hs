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
import Control.Monad (forever, replicateM, replicateM_)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (forkIO, threadDelay, ThreadId)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Distributed.Process
  ( RemoteTable
  , NodeId
  , Process
  , ProcessId
  , WhereIsReply(..)
  , whereis
  , whereisRemoteAsync
  , getSelfPid
  , register
  , reregister
  , expect
  , nsendRemote
  , receiveWait
  , match
  , processNodeId
  , monitorNode
  , monitor
  , unmonitor
  , NodeMonitorNotification(..)
  , ProcessRegistrationException
  , finally
  , newChan
  , receiveChan
  , nsend
  , SendPort
  , bracket
  , try
  , send
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
  , redirectLogsHere :: [ProcessId] -> Process ()
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
  (recv, sendp) <- initMulticast  "224.0.0.99" 9999 1024
  (_, backendState) <- fixIO $ \ ~(tid, _) -> do
    backendState <- newMVar BackendState
                      { _localNodes      = []
                      , _peers           = Set.empty
                      ,  discoveryDaemon = tid
                      }
    tid' <- forkIO $ peerDiscoveryDaemon backendState recv sendp
    return (tid', backendState)
  case mTransport of
    Left err -> throw err
    Right transport ->
      let backend = Backend {
          newLocalNode       = apiNewLocalNode transport rtable backendState
        , findPeers          = apiFindPeers sendp backendState
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
apiFindPeers sendfn backendState delay = do
  sendfn PeerDiscoveryRequest
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
peerDiscoveryDaemon backendState recv sendfn = forever go
  where
    go = do
      (msg, _) <- recv
      case msg of
        PeerDiscoveryRequest -> do
          nodes <- (^. localNodes) <$> readMVar backendState
          forM_ nodes $ sendfn . PeerDiscoveryReply . Node.localNodeId
        PeerDiscoveryReply nid ->
          modifyMVar_ backendState $ return . (peers ^: Set.insert nid)

--------------------------------------------------------------------------------
-- Back-end specific primitives                                               --
--------------------------------------------------------------------------------

-- | Make sure that all log messages are printed by the logger on this node
apiRedirectLogsHere :: Backend -> [ProcessId] -> Process ()
apiRedirectLogsHere _backend slavecontrollers = do
  mLogger <- whereis "logger"
  myPid <- getSelfPid

  forM_ mLogger $ \logger -> do

  bracket
   (mapM monitor slavecontrollers)
   (mapM unmonitor)
   $ \_ -> do

   -- fire off redirect requests
   forM_ slavecontrollers $ \pid -> send pid (RedirectLogsTo logger myPid)

   -- Wait for the replies
   replicateM_ (length slavecontrollers) $ do
     receiveWait
       [ match (\(RedirectLogsReply {}) -> return ())
       , match (\(NodeMonitorNotification {}) -> return ())
       ]

--------------------------------------------------------------------------------
-- Slaves                                                                     --
--------------------------------------------------------------------------------

-- | Messages to slave nodes
--
-- This datatype is not exposed; instead, we expose primitives for dealing
-- with slaves.
data SlaveControllerMsg
   = SlaveTerminate
   | RedirectLogsTo ProcessId ProcessId
  deriving (Typeable, Show)

instance Binary SlaveControllerMsg where
  put SlaveTerminate = putWord8 0
  put (RedirectLogsTo a b) = do putWord8 1; put (a,b)
  get = do
    header <- getWord8
    case header of
      0 -> return SlaveTerminate
      1 -> do (a,b) <- get; return (RedirectLogsTo a b)
      _ -> fail "SlaveControllerMsg.get: invalid"

data RedirectLogsReply
  = RedirectLogsReply ProcessId Bool
  deriving (Typeable, Show)

instance Binary RedirectLogsReply where
  put (RedirectLogsReply from ok) = put (from,ok)
  get = do
    (from,ok) <- get
    return (RedirectLogsReply from ok)

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
        RedirectLogsTo loggerPid from -> do
          r <- try (reregister "logger" loggerPid)
          ok <- case (r :: Either ProcessRegistrationException ()) of
                  Right _ -> return True
                  Left _  -> do
                    s <- try (register "logger" loggerPid)
                    case (s :: Either ProcessRegistrationException ()) of
                      Right _ -> return True
                      Left _  -> return False
          pid <- getSelfPid
          send from (RedirectLogsReply pid ok)
          go

-- | Terminate the slave at the given node ID
terminateSlave :: NodeId -> Process ()
terminateSlave nid = nsendRemote nid "slaveController" SlaveTerminate

-- | Find slave nodes
findSlaves :: Backend -> Process [ProcessId]
findSlaves backend = do
  nodes <- liftIO $ findPeers backend 1000000
  -- Fire off asynchronous requests for the slave controller

  bracket
   (mapM monitorNode nodes)
   (mapM unmonitor)
   $ \_ -> do

   -- fire off whereis requests
   forM_ nodes $ \nid -> whereisRemoteAsync nid "slaveController"

   -- Wait for the replies
   catMaybes <$> replicateM (length nodes) (
     receiveWait
       [ match (\(WhereIsReply "slaveController" mPid) -> return mPid)
       , match (\(NodeMonitorNotification {}) -> return Nothing)
       ])

-- | Terminate all slaves
terminateAllSlaves :: Backend -> Process ()
terminateAllSlaves backend = do
  slaves <- findSlaves backend
  forM_ slaves $ \pid -> send pid SlaveTerminate
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
    redirectLogsHere backend slaves
    proc (map processNodeId slaves) `finally` shutdownLogger

--
-- | shut down the logger process. This ensures that any pending
-- messages are flushed before the process exits.
--
shutdownLogger :: Process ()
shutdownLogger = do
  (sport,rport) <- newChan
  nsend "logger" (sport :: SendPort ())
  receiveChan rport
  -- TODO: we should monitor the logger process so we don't deadlock if
  -- it has already died.

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localNodes :: Accessor BackendState [Node.LocalNode]
localNodes = accessor _localNodes (\ns st -> st { _localNodes = ns })

peers :: Accessor BackendState (Set NodeId)
peers = accessor _peers (\ps st -> st { _peers = ps })
