module Control.Distributed.Process 
  ( -- * Cloud Haskell API
    ProcessId
  , Process
  , expect
  , send 
  , getSelfPid
    -- * Initialization
  , newLocalNode
  , forkProcess
  , runProcess
  ) where

import qualified Data.ByteString as BSS (ByteString, concat)
import qualified Data.ByteString.Lazy as BSL ( ByteString
                                             , toChunks
                                             , fromChunks
                                             , splitAt
                                             )
import Data.Binary (Binary, decode, encode, put, get)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty, lookup, insert, delete)
import qualified Data.List as List (delete)
import Data.Typeable (Typeable)
import Control.Monad (void, liftM2)
import Control.Monad.Reader (MonadReader(..), ReaderT, runReaderT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Applicative ((<$>))
import Control.Category ((>>>))
import Control.Exception (throwIO)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar ( MVar
                               , newMVar
                               , withMVar
                               , modifyMVar
                               , modifyMVar_
                               , newEmptyMVar
                               , putMVar
                               , takeMVar
                               )
import Control.Distributed.Process.Internal.CQueue ( CQueue 
                                                   , dequeueMatching
                                                   , enqueue
                                                   , newCQueue
                                                   )
import Control.Distributed.Process.Serializable ( Serializable
                                                , Fingerprint
                                                , encodeFingerprint
                                                , decodeFingerprint
                                                , fingerprint
                                                , sizeOfFingerprint
                                                )
import qualified Network.Transport as NT ( Transport
                                         , EndPoint
                                         , EndPointAddress
                                         , Connection
                                         , Reliability(ReliableOrdered)
                                         , defaultConnectHints
                                         , send
                                         , connect
                                         , close
                                         , newEndPoint
                                         , receive
                                         , Event(..)
                                         , address
                                         )
import qualified Network.Transport.Internal as NTI (encodeInt32, decodeInt32)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe, intMapMaybe)

type LocalProcessId = Int

data ProcessId = ProcessId 
  { processAddress :: NT.EndPointAddress 
  , processLocalId :: LocalProcessId 
  }
  deriving (Eq, Ord, Typeable, Show)

instance Binary ProcessId where
  put pid = do put (processAddress pid)
               put (processLocalId pid)
  get = liftM2 ProcessId get get

data Message = Message 
  { messageFingerprint :: Fingerprint 
  , messageEncoding    :: BSL.ByteString
  }

data LocalNode = LocalNode 
  { localEndPoint :: NT.EndPoint 
  , localState    :: MVar LocalNodeState
  }

data LocalNodeState = LocalNodeState 
  { _localConnections :: Map ProcessId NT.Connection
  , _localProcesses   :: IntMap ProcessState
  , _localNextProcId  :: LocalProcessId 
  }

data ProcessState = ProcessState 
  { processQueue :: CQueue Message 
  , processNode  :: LocalNode   
  , processId    :: ProcessId
  }

newtype Process a = Process { unProcess :: ReaderT ProcessState IO a }
  deriving (Functor, Monad, MonadIO, MonadReader ProcessState)

--------------------------------------------------------------------------------
-- Cloud Haskell API                                                          --
--------------------------------------------------------------------------------

expect :: forall a. Serializable a => Process a
expect = do
  queue <- processQueue <$> ask 
  let fp = fingerprint (undefined :: a)
  msg <- liftIO $ dequeueMatching queue ((== fp) . messageFingerprint)
  return (decode . messageEncoding $ msg)

send :: Serializable a => ProcessId -> a -> Process ()
send pid msg = do
  -- This requires a lookup on every send. If we want to avoid that we need to
  -- modify serializable to allow for stateful (IO) deserialization
  node <- processNode <$> ask
  liftIO $ do
    conn <- connectionTo node pid
    sendBinary node pid conn ( encodeFingerprint (fingerprint msg)
                             : BSL.toChunks (encode msg)
                             )

getSelfPid :: Process ProcessId
getSelfPid = processId <$> ask 

--------------------------------------------------------------------------------
-- Initialization                                                             --
--------------------------------------------------------------------------------

newLocalNode :: NT.Transport -> IO LocalNode
newLocalNode transport = do
  mEndPoint <- NT.newEndPoint transport
  case mEndPoint of
    Left ex -> throwIO ex
    Right endPoint -> do
      state <- newMVar LocalNodeState 
        { _localConnections = Map.empty
        , _localProcesses   = IntMap.empty
        , _localNextProcId  = firstNonReservedProcessId
        }
      let node = LocalNode { localEndPoint = endPoint
                           , localState    = state
                           }
      void . forkIO $ handleIncomingMessages node
      return node

runProcess :: LocalNode -> Process () -> IO ()
runProcess node proc = do
  done <- newEmptyMVar
  void $ forkProcess node (proc >> liftIO (putMVar done ()))
  takeMVar done

forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess node proc = do
  queue <- newCQueue
  state <- modifyMVar (localState node) $ \st -> do
    let lpid  = st ^. localNextProcId
    let pid   = ProcessId { processAddress = NT.address (localEndPoint node)
                          , processLocalId = lpid
                          }
    let state = ProcessState { processQueue = queue
                             , processNode  = node
                             , processId    = pid
                             }
    return ( (localProcessWithId lpid ^= Just state)
           . (localNextProcId ^: (+ 1))
           $ st
           , state 
           )
  void . forkIO $ runReaderT (unProcess proc) state 
  return (processId state)
   
handleIncomingMessages :: LocalNode -> IO ()
handleIncomingMessages node = go [] IntMap.empty
  where
    go halfOpenConns openConns = do
      event <- NT.receive endpoint
      case event of
        NT.ConnectionOpened cid _rel _theirAddr ->
          go (cid : halfOpenConns) openConns
        NT.Received cid payload -> 
          case IntMap.lookup cid openConns of
            Just proc -> do
              let msg = payloadToMessage payload
              enqueue (processQueue proc) msg
              go halfOpenConns openConns
            Nothing -> if cid `elem` halfOpenConns
              then do
                let pid = NTI.decodeInt32 . BSS.concat $ payload 
                mProc <- withMVar state $ return . (^. localProcessWithId pid) 
                case mProc of
                  Just proc -> 
                    go (List.delete pid halfOpenConns) 
                       (IntMap.insert cid proc openConns)
                  Nothing ->
                    fail "TODO"
              else
                fail "TODO" 
        NT.ConnectionClosed cid -> 
          go (List.delete cid halfOpenConns) (IntMap.delete cid openConns)
        NT.ErrorEvent _ ->
          fail "TODO"
        NT.EndPointClosed ->
          return ()
        NT.ReceivedMulticast _ _ ->
          fail "Unexpected multicast"
    
    state    = localState node
    endpoint = localEndPoint node

--------------------------------------------------------------------------------
-- Auxiliary functions                                                        --
--------------------------------------------------------------------------------

connectionTo :: LocalNode -> ProcessId -> IO NT.Connection
connectionTo node pid = do
  mConn <- withMVar (localState node) $ return . (^. localConnectionTo pid)
  case mConn of
    Just conn -> return conn
    Nothing   -> createConnectionTo node pid

createConnectionTo :: LocalNode -> ProcessId -> IO NT.Connection
createConnectionTo node pid = do 
  mConn <- NT.connect (localEndPoint node) 
                      (processAddress pid)  
                      NT.ReliableOrdered
                      NT.defaultConnectHints
  case mConn of
    Right conn -> do
      mConn' <- modifyMVar (localState node) $ \st ->
        case st ^. localConnectionTo pid of
          Just conn' -> return (st, Just conn')
          Nothing    -> return ( localConnectionTo pid ^= Just conn $ st
                               , Nothing
                               )
      case mConn' of
        Just conn' -> do
          -- Somebody else already created a connection while we weren't looking
          -- (We don't want to keep localConnections locked while creating the
          -- connection because that would limit concurrency too much, and
          -- since Network.Transport supports lgihtweight connections creating
          -- an unnecessary connection now and then is cheap anyway)
          NT.close conn
          return conn'
        Nothing -> do
          sendBinary node pid conn [NTI.encodeInt32 . processLocalId $ pid] 
          return conn
    Left err ->
      throwIO err

sendBinary :: LocalNode 
           -> ProcessId 
           -> NT.Connection 
           -> [BSS.ByteString] 
           -> IO ()
sendBinary node pid conn msg = do
  result <- NT.send conn msg
  case result of
    Right () -> return ()
    Left err -> do  
      modifyMVar_ (localState node) $ 
        return . (localConnectionTo pid ^= Nothing)
      throwIO err

payloadToMessage :: [BSS.ByteString] -> Message
payloadToMessage payload = Message fp msg
  where
    (encFp, msg) = BSL.splitAt (fromIntegral sizeOfFingerprint) 
                 $ BSL.fromChunks payload 
    fp = decodeFingerprint . BSS.concat . BSL.toChunks $ encFp

--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

firstNonReservedProcessId :: Int
firstNonReservedProcessId = 1024

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localConnections :: Accessor LocalNodeState (Map ProcessId NT.Connection)
localConnections = accessor _localConnections (\conns st -> st { _localConnections = conns })

localProcesses :: Accessor LocalNodeState (IntMap ProcessState)
localProcesses = accessor _localProcesses (\procs st -> st { _localProcesses = procs })

localNextProcId :: Accessor LocalNodeState Int
localNextProcId = accessor _localNextProcId (\pid st -> st { _localNextProcId = pid })

localConnectionTo :: ProcessId -> Accessor LocalNodeState (Maybe NT.Connection)
localConnectionTo pid = localConnections >>> DAC.mapMaybe pid

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe ProcessState)
localProcessWithId lpid = localProcesses >>> DAC.intMapMaybe lpid

{-
{-# LANGUAGE CPP, ExplicitForAll, ScopedTypeVariables #-}

module Control.Distributed.Process (
    -- * Processes
    Process,
    liftIO,
    ProcessId,
--    NodeId,

    -- * Basic messaging
    send,
    expect,

    -- * Process management
    spawnLocal,
    getSelfPid,
--    getSelfNode,

    -- * Initialisation
    Transport,
    LocalNode,
    newLocalNode,
    runProcess,

  ) where

import qualified Network.Transport as Trans
import Network.Transport (Transport)

import qualified Data.IntMap as IntMap
import Data.IntMap (IntMap)
import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Concurrent.MVar
import Control.Concurrent.Chan
import Control.Concurrent
import Data.Typeable

import Debug.Trace

#ifndef LAZY
import qualified Data.ByteString.Char8 as BS
import Data.ByteString.Char8 (ByteString)
#else
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.ByteString.Lazy.Char8 (ByteString)
#endif

------------------------
-- Cloud Haskell layer
--

data NodeId = NodeId -- !Trans.SourceEnd !Trans.SourceEnd

data ProcessId = ProcessId !Trans.SourceEnd !NodeId !LocalProcessId
type LocalProcessId = Int

newtype SourcePort a = SourcePort Trans.SourceEnd

newtype Process a = Process { unProcess :: ProcessState -> IO a }

instance Functor Process where
    fmap f m = Process (\ps -> unProcess m ps >>= \x -> return (f x))

instance Applicative Process where
    pure  = return
    (<*>) = ap

instance Monad Process where
    m >>= k  = Process (\ps -> unProcess m ps >>= \x -> unProcess (k x) ps)
    return x = Process (\_  -> return x)

instance MonadIO Process where
    liftIO io = Process (\_ -> io)

getProcessState :: Process ProcessState
getProcessState = Process (\ps  -> return ps)

getLocalNode :: Process LocalNode
getLocalNode = prNode <$> getProcessState

getSelfPid :: Process ProcessId
getSelfPid = prPid <$> getProcessState

-- State a process carries around and has local access to
--
data ProcessState = ProcessState {
    prPid   :: !ProcessId,
    prChan  :: !Trans.TargetEnd,
    prQueue :: !(CQueue Message),
    prNode  :: !LocalNode
  }

data Message = Message String --string rep of TypeRep, sigh.
                       String

-- Context for a local node, all processes running on a node have direct access to this
--
data LocalNode = LocalNode {
    ndProcessTable  :: !(MVar ProcessTable),
    ndTransport     :: !Transport
  }

data ProcessTable = ProcessTable
  !LocalProcessId              -- ^ Value of next ProcessTableEntry index
  !(IntMap ProcessTableEntry)  -- ^ Index from LocalProcessIds to ProcessTableEntry
data ProcessTableEntry = ProcessTableEntry {
    pteThread :: !ThreadId
  }

newLocalNode :: Transport -> IO LocalNode
newLocalNode trans = do
    processTableVar  <- newMVar (ProcessTable 0 IntMap.empty)
    return LocalNode {
      ndProcessTable  = processTableVar,
      ndTransport     = trans
    }

-- | `runProcess` executes a process on a given node, and waits for the process
-- to finish before returning.
runProcess :: LocalNode -> Process () -> IO ()
runProcess node proc = do
  waitVar <- newEmptyMVar
  _ <- forkProcess node (proc >> liftIO (putMVar waitVar ()))
         --TODO: should use linking for waiting for the end
  takeMVar waitVar

-- | `forkProcess` forks and executes process on a given node. This
-- returns the ProcessId when the new process has been created.
forkProcess :: LocalNode -> Process () -> IO ProcessId
forkProcess node (Process action) = do
    (sourceAddr, chan) <- Trans.newConnection (ndTransport node)
    sourceEnd <- Trans.connect sourceAddr
    processTable@(ProcessTable lpid _) <- takeMVar (ndProcessTable node)
    let pid = ProcessId sourceEnd NodeId lpid
    _ <- forkIO $ do
      tid  <- myThreadId
      putMVar (ndProcessTable node) (insertProcess tid processTable)
      queue <- newCQueue
      _ <- forkIO $ receiverPump chan queue
      action $ ProcessState pid chan queue node
    return pid

  where
    insertProcess :: ThreadId -> ProcessTable -> ProcessTable
    insertProcess tid (ProcessTable nextPid table) =
      let pte = ProcessTableEntry tid
       in ProcessTable (nextPid+1) (IntMap.insert nextPid pte table)

    receiverPump :: Trans.TargetEnd -> CQueue Message -> IO ()
    receiverPump chan queue = forever $ do
      msgBlobs <- Trans.receive chan
      readBlobs (concatMap BS.unpack msgBlobs)
     where
      readBlobs :: String -> IO ()
      readBlobs [] = return ()
      readBlobs bs = do
        -- TODO: replace reads with something safer and faster.
        let [((typerep, body), bs')] = reads bs
        enqueue queue (Message typerep body)
        readBlobs bs'

send :: (Typeable a, Show a) => ProcessId -> a -> Process ()
send (ProcessId chan _ _) msg =
    liftIO (Trans.send chan msgBlobs)
  where
    msgBlobs :: [ByteString]
    msgBlobs =  [BS.pack (show (show (typeOf msg), show msg))]

expect :: forall a. (Typeable a, Read a) => Process a
expect = do
    ProcessState { prQueue = queue } <- getProcessState
    let typerepstr = show (typeOf (undefined :: a))
    Message _ body <- liftIO $
      dequeueMatching queue (\(Message typerepstr' _) -> typerepstr' == typerepstr)
    return (read body)

spawnLocal :: Process () -> Process ProcessId
spawnLocal proc = do
  node <- getLocalNode
  liftIO $ forkProcess node proc

{-
send   :: Serializable a -> ProcessId -> a -> Process ()
expect :: Serializable a -> Process a

newChan     :: Serializable a => Process (SourcePort a, TargetPort a)
sendChan    :: Serializable a => SourcePort a -> a -> Process ()
receiveChan :: Serializable a => TargetPort a -> Process a

spawn       :: NodeId -> Closure (Process ()) -> Process ProcessId
terminate   :: ProcessM a
getSelfPid  :: ProcessM ProcessId
getSelfNode :: ProcessM NodeId

monitorProcess :: ProcessId -> ProcessId -> MonitorAction -> Process ()

-}

--
-}        
