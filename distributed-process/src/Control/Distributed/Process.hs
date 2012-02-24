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

-- Concurrent queue for single reader, single writer
--
data CQueue a = CQueue (MVar [a]) -- arrived
                       (Chan a) -- incomming

newCQueue :: IO (CQueue a)
newCQueue = do
  arrived   <- newMVar []
  incomming <- newChan
  return (CQueue arrived incomming)

enqueue :: CQueue a -> a -> IO ()
enqueue (CQueue _arrived incomming) a = writeChan incomming a

dequeueMatching :: forall a. CQueue a -> (a -> Bool) -> IO a
dequeueMatching (CQueue arrived incomming) matches = do
    modifyMVar arrived (checkArrived [])
  where
    checkArrived :: [a] -> [a] -> IO ([a], a)
    checkArrived xs' []     = checkIncomming xs'
    checkArrived xs' (x:xs)
                | matches x = return (reverse xs' ++ xs, x)
                | otherwise = checkArrived (x:xs') xs

    checkIncomming :: [a] -> IO ([a], a)
    checkIncomming xs' = do
      x <- readChan incomming
      if matches x
        then return (reverse xs', x)
        else checkIncomming (x:xs')
