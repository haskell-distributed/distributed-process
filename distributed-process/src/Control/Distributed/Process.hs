-- | Cloud Haskell
-- 
-- 1.  'send' never fails. If you want to know that the remote process received
--     your message, you will need to send an explicit acknowledgement. If you
--     want to know when the remote process failed, you will need to monitor
--     that remote process.
--
-- 2.  'send' may block (when the system TCP buffers are full, while we are
--     trying to establish a connection to the remote endpoint, etc.) but its
--     return does not imply that the remote process received the message (much
--     less processed it)
--
-- 3.  Message delivery is reliable and ordered. That means that if process A
--     sends messages m1, m2, m3 to process B, B will either arrive all three
--     messages in order (m1, m2, m3) or a prefix thereof; messages will not be
--     'missing' (m1, m3) or reordered (m1, m3, m2)
--
-- In order to guarantee (3), we stipulate that
--
-- 3a. Once a connection to a remote process fails, that process is considered
--     forever unreachable. When the remote process restarts, it will receive a
--     brand new ProcessId.
--
-- 3b. We do not garbage collect (lightweight) connections, because we have
--     ordering guarantees from Network.Transport only per lightweight
--     connection.  We could lift this restriction later, if we wish, by adding
--     some acknowledgement control messages: we can drop one lightweight
--     connection and open another once we know that all messages sent on the
--     former have been received.
--
-- Main reference for Cloud Haskell is
--
-- [1] "Towards Haskell in the Cloud", Jeff Epstein, Andrew Black and Simon
--     Peyton-Jones.
--       http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
--
-- Some pointers to related documentation about Erlang, for comparison and
-- inspiration: 
--
-- [1] "Programming Distributed Erlang Applications: Pitfalls and Recipes",
--     Hans Svensson and Lars-Ake Fredlund 
--       http://man.lupaworld.com/content/develop/p37-svensson.pdf
-- [2] The Erlang manual, sections "Message Sending" and "Send" 
--       http://www.erlang.org/doc/reference_manual/processes.html#id82409
--       http://www.erlang.org/doc/reference_manual/expressions.html#send
-- [3] Questions "Is the order of message reception guaranteed?" and
--     "If I send a message, is it guaranteed to reach the receiver?" of
--     the Erlang FAQ
--       http://www.erlang.org/faq/academic.html
-- [4] "Delivery of Messages", post on erlang-questions
--       http://erlang.org/pipermail/erlang-questions/2012-February/064767.html
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

import qualified Data.ByteString as BSS (ByteString, concat, splitAt)
import qualified Data.ByteString.Lazy as BSL ( ByteString
                                             , toChunks
                                             , fromChunks
                                             , splitAt
                                             )
import Data.Binary (Binary, decode, encode, put, get)
import Data.Map (Map)
import qualified Data.Map as Map (empty, lookup, insert, delete)
import qualified Data.List as List (delete)
import Data.Int (Int32)
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
import qualified Data.Accessor.Container as DAC (mapMaybe)
import System.Random (randomIO)

data LocalProcessId = LocalProcessId 
  { pidUnique  :: Int32
  , pidCounter :: Int32
  }
  deriving (Eq, Ord, Typeable, Show)

instance Binary LocalProcessId where
  put lpid = put (pidUnique lpid) >> put (pidCounter lpid)
  get      = liftM2 LocalProcessId get get

data ProcessId = ProcessId 
  { processAddress :: NT.EndPointAddress 
  , processLocalId :: LocalProcessId 
  }
  deriving (Eq, Ord, Typeable, Show)

instance Binary ProcessId where
  put pid = put (processAddress pid) >> put (processLocalId pid)
  get     = liftM2 ProcessId get get

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
  , _localProcesses   :: Map LocalProcessId ProcessState
  , _localPidCounter  :: Int32
  , _localPidUnique   :: Int32
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
      unq <- randomIO
      state <- newMVar LocalNodeState 
        { _localConnections = Map.empty
        , _localProcesses   = Map.empty
        , _localPidCounter  = 0 
        , _localPidUnique   = unq 
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
    let lpid  = LocalProcessId { pidCounter = st ^. localPidCounter
                               , pidUnique  = st ^. localPidUnique
                               }
    let pid   = ProcessId { processAddress = NT.address (localEndPoint node)
                          , processLocalId = lpid
                          }
    let state = ProcessState { processQueue = queue
                             , processNode  = node
                             , processId    = pid
                             }
    -- TODO: if the counter overflows we should pick a new unique                           
    return ( (localProcessWithId lpid ^= Just state)
           . (localPidCounter ^: (+ 1))
           $ st
           , state 
           )
  void . forkIO $ runReaderT (unProcess proc) state 
  return (processId state)
   
handleIncomingMessages :: LocalNode -> IO ()
handleIncomingMessages node = go [] Map.empty
  where
    go halfOpenConns openConns = do
      event <- NT.receive endpoint
      case event of
        NT.ConnectionOpened cid _rel _theirAddr ->
          go (cid : halfOpenConns) openConns
        NT.Received cid payload -> 
          case Map.lookup cid openConns of
            Just proc -> do
              let msg = payloadToMessage payload
              enqueue (processQueue proc) msg
              go halfOpenConns openConns
            Nothing -> if cid `elem` halfOpenConns
              then do
                let lpid = payloadToLpid payload
                mProc <- withMVar state $ return . (^. localProcessWithId lpid) 
                case mProc of
                  Just proc -> 
                    go (List.delete cid halfOpenConns) 
                       (Map.insert cid proc openConns)
                  Nothing ->
                    fail "handleIncomingMessages: TODO 1"
              else
                fail "handleIncomingMessages: TODO 2" 
        NT.ConnectionClosed cid -> 
          go (List.delete cid halfOpenConns) (Map.delete cid openConns)
        NT.ErrorEvent _ ->
          fail "handleIncomingMessages: TODO 3"
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
          sendBinary node pid conn $ lpidToPayload (processLocalId pid) 
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

lpidToPayload :: LocalProcessId -> [BSS.ByteString]
lpidToPayload lpid = [ NTI.encodeInt32 (pidCounter lpid)
                     , NTI.encodeInt32 (pidUnique lpid)
                     ]

payloadToLpid :: [BSS.ByteString] -> LocalProcessId
payloadToLpid bss = let (bs1, bs2) = BSS.splitAt 4 . BSS.concat $ bss
                    in LocalProcessId { pidCounter = NTI.decodeInt32 bs1
                                      , pidUnique  = NTI.decodeInt32 bs2
                                      }
                        
--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localConnections :: Accessor LocalNodeState (Map ProcessId NT.Connection)
localConnections = accessor _localConnections (\conns st -> st { _localConnections = conns })

localProcesses :: Accessor LocalNodeState (Map LocalProcessId ProcessState)
localProcesses = accessor _localProcesses (\procs st -> st { _localProcesses = procs })

localPidCounter :: Accessor LocalNodeState Int32
localPidCounter = accessor _localPidCounter (\ctr st -> st { _localPidCounter = ctr })

localPidUnique :: Accessor LocalNodeState Int32
localPidUnique = accessor _localPidUnique (\unq st -> st { _localPidUnique = unq })

localConnectionTo :: ProcessId -> Accessor LocalNodeState (Maybe NT.Connection)
localConnectionTo pid = localConnections >>> DAC.mapMaybe pid

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe ProcessState)
localProcessWithId lpid = localProcesses >>> DAC.mapMaybe lpid
