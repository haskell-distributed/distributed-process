-- | TCP implementation of the transport layer. 
-- 
-- The TCP implementation guarantees that only a single TCP connection (socket)
-- will be used between endpoints, provided that the addresses specified are
-- canonical. If /A/ connects to /B/ and reports its address as
-- @192.168.0.1:8080@ and /B/ subsequently connects tries to connect to /A/ as
-- @client1.local:http-alt@ then the transport layer will not realize that the
-- TCP connection can be reused. 
--
-- Applications that use the TCP transport should use
-- 'Network.Socket.withSocketsDo' in their main function for Windows
-- compatibility (see "Network.Socket").
--
-- TODOs:
-- * Output exception on channel after endpoint is closed
module Network.Transport.TCP ( -- * Main API
                               createTransport
                             , -- * TCP specific functionality (exported mostly for testing purposes_
                               EndPointId
                             , encodeEndPointAddress
                             , decodeEndPointAddress
                             , ControlHeader(..)
                             , ConnectionRequestResponse(..)
                             , firstNonReservedConnectionId
                             , socketToEndPoint 
                               -- * Design notes
                               -- $design
                             ) where

import Prelude hiding (catch)
import Network.Transport
import Network.Transport.Internal.TCP ( forkServer
                                      , recvWithLength
                                      , recvInt32
                                      )
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
                                  , prependLength
                                  , mapExceptionIO
                                  , tryIO
                                  , tryToEnum
                                  , void
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , sClose
                                     , getAddrInfo
                                     , socket
                                     , addrFamily
                                     , addrAddress
                                     , SocketType(Stream)
                                     , defaultProtocol
                                     , setSocketOption
                                     , SocketOption(ReuseAddr) 
                                     , connect
                                     , sOMAXCONN
                                     , AddrInfo
                                     )
import Network.Socket.ByteString (sendMany)
import Control.Concurrent (forkIO, ThreadId, killThread, myThreadId)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar ( MVar
                               , newMVar
                               , modifyMVar
                               , modifyMVar_
                               , readMVar
                               , takeMVar
                               , putMVar
                               , newEmptyMVar
                               , withMVar
                               )
import Control.Category ((>>>))
import Control.Applicative ((<$>))
import Control.Monad (forM_, when, unless)
import Control.Exception (IOException, SomeException, handle, throw, try, bracketOnError)
import Data.IORef (IORef, newIORef, writeIORef, readIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack, split)
import Data.Int (Int32)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet (empty, insert, elems, singleton, null, delete)
import Data.Map (Map)
import qualified Data.Map as Map (empty, elems, size)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:)) 
import qualified Data.Accessor.Container as DAC (mapMaybe, intMapMaybe)
import System.IO (hPutStrLn, stderr)

-- $design 
--
-- [Goals]
--
-- The TCP transport maps multiple logical connections between /A/ and /B/ (in
-- either direction) to a single TCP connection:
--
-- > +-------+                          +-------+
-- > | A     |==========================| B     |
-- > |       |>~~~~~~~~~~~~~~~~~~~~~~~~~|~~~\   |
-- > |   Q   |>~~~~~~~~~~~~~~~~~~~~~~~~~|~~~Q   |
-- > |   \~~~|~~~~~~~~~~~~~~~~~~~~~~~~~<|       |
-- > |       |==========================|       |
-- > +-------+                          +-------+
-- 
-- Ignoring the complications detailed below, the TCP connection is set up is
-- when the first lightweight connection is created (in either direction), and
-- torn down when the last lightweight connection (in either direction) is
-- closed.
--
-- [Connecting]
--
-- Let /A/, /B/ be two endpoints without any connections. When /A/ wants to
-- connect to /B/, it locally records that it is trying to connect to /B/ and
-- sends a request to /B/. As part of the request /A/ sends its own endpoint
-- address to /B/ (so that /B/ can reuse the connection in the other direction).
--
-- When /B/ receives the connection request it first checks if it did not
-- already initiate a connection request to /A/. If not it will acknowledge the
-- connection request by sending 'ConnectionRequestAccepted' to /A/ and record
-- that it has a TCP connection to /A/.
--
-- The tricky case arises when /A/ sends a connection request to /B/ and /B/
-- finds that it had already sent a connection request to /A/. In this case /B/
-- will accept the connection request from /A/ if /A/s endpoint address is
-- smaller (lexicographically) than /B/s, and reject it otherwise. If it rejects
-- it, it sends a 'ConnectionRequestCrossed' message to /A/. (The
-- lexicographical ordering is an arbitrary but convenient way to break the
-- tie.)
--
-- When it receives a 'ConnectionRequestCrossed' message the /A/ thread that
-- initiated the request just needs to wait until the /A/ thread that is dealing
-- with /B/'s connection request completes.
--
-- [Disconnecting]
-- 
-- The TCP connection is created as soon as the first logical connection from
-- /A/ to /B/ (or /B/ to /A/) is established. At this point a thread (@#@) is
-- spawned that listens for incoming connections from /B/:
--
-- > +-------+                          +-------+
-- > | A     |==========================| B     |
-- > |       |>~~~~~~~~~~~~~~~~~~~~~~~~~|~~~\   |
-- > |       |                          |   Q   |
-- > |      #|                          |       |
-- > |       |==========================|       |
-- > +-------+                          +-------+
--
-- The question is when the TCP connection can be closed again.  Conceptually,
-- we want to do reference counting: when there are no logical connections left
-- between /A/ and /B/ we want to close the socket (possibly after some
-- timeout). 
--
-- However, /A/ and /B/ need to agree that the refcount has reached zero.  It
-- might happen that /B/ sends a connection request over the existing socket at
-- the same time that /A/ closes its logical connection to /B/ and closes the
-- socket. This will cause a failure in /B/ (which will have to retry) which is
-- not caused by a network failure, which is unfortunate. (Note that the
-- connection request from /B/ might succeed even if /A/ closes the socket.) 
--
-- Instead, when /A/ is ready to close the socket it sends a 'CloseSocket'
-- request to /B/ and records that its connection to /B/ is closing. If /A/
-- receives a new connection request from /B/ after having sent the
-- 'CloseSocket' request it simply forgets that it sent a 'CloseSocket' request
-- and increments the reference count of the connection again.
-- 
-- When /B/ receives a 'CloseSocket' message and it too is ready to close the
-- connection, it will respond with a reciprocal 'CloseSocket' request to /A/
-- and then actually close the socket. /A/ meanwhile will not send any more
-- requests to /B/ after having sent a 'CloseSocket' request, and will actually
-- close its end of the socket only when receiving the 'CloseSocket' message
-- from /B/. (Since /A/ recorded that its connection to /B/ is in closing state
-- after sending a 'CloseSocket' request to /B/, it knows not to reciprocate /B/
-- reciprocal 'CloseSocket' message.)
-- 
-- If there is a concurrent thread in /A/ waiting to connect to /B/ after /A/
-- has sent a 'CloseSocket' request then this thread will block until /A/ knows
-- whether to reuse the old socket (if /B/ sends a new connection request
-- instead of acknowledging the 'CloseSocket') or to set up a new socket. 

--------------------------------------------------------------------------------
-- Internal datatypes                                                         --
--------------------------------------------------------------------------------

-- We use underscores for fields that we might update (using accessores)
--
-- All data types follow the same structure:
-- 
-- * A top-level data type describing static properties (TCPTransport,
--   LocalEndPoint, RemoteEndPoint)
-- * The 'static' properties include an MVar containing a data structure for
--   the dynamic properties (TransportState, LocalEndPointState,
--   RemoteEndPointState). The state could be invalid/valid/closed,/etc.  
-- * For the case of "valid" we use third data structure to give more details
--   about the state (ValidTransportState, ValidLocalEndPointState,
--   ValidRemoteEndPointState).

data TCPTransport = TCPTransport 
  { transportHost  :: N.HostName
  , transportPort  :: N.ServiceName
  , transportState :: MVar TransportState 
  }

data TransportState = 
    TransportValid ValidTransportState
  | TransportClosed

data ValidTransportState = ValidTransportState 
  { _localEndPoints :: Map EndPointAddress LocalEndPoint 
  }

data LocalEndPoint = LocalEndPoint
  { localAddress :: EndPointAddress
  , localChannel :: Chan Event
  , localState   :: MVar LocalEndPointState 
  }

data LocalEndPointState = 
    LocalEndPointValid ValidLocalEndPointState
  | LocalEndPointClosed

data ValidLocalEndPointState = ValidLocalEndPointState 
  { _nextConnectionId    :: ConnectionId 
  , _pendingCtrlRequests :: IntMap (MVar [ByteString])
  , _nextCtrlRequestId   :: ControlRequestId 
  , _localConnections    :: Map EndPointAddress RemoteEndPoint 
  , _internalThreads     :: [ThreadId]
  }

-- A remote endpoint has incoming and outgoing connections, and when the total
-- number of connections (that is, the 'remoteRefCount') drops to zero we want
-- to close the TCP connection to the endpoint. 
--
-- What we need to avoid, however, is a situation with two concurrent threads
-- where one closes the last (incoming or outgoing) connection, initiating the
-- process of closing the connection, while another requests (but does not yet
-- have) a new connection.
--
-- We therefore insist that:
-- 
-- 1. All operations that change the state of the endpoint (ask for a new
--    connection, close a connection, close the endpoint completely) are
--    serialized (that is, they take the contents of the MVar containing the
--    endpoint state before starting and don't put the updated contents back
--    until they have completed). 
-- 2. Writing to ('apiSend') or reading from (in 'handleIncomingMessages') must
--    maintain the invariant that the connection they are writing to/reading
--    from *must* be "included" in the 'remoteRefCount'. 
-- 3. Since every endpoint is associated with a single socket, we regard writes
--    that endpoint a state change too (i.e., we take the MVar before the write
--    and put it back after). The reason is that we don't want to "scramble" the
--    output of multiple concurrent writes (either from an explicit 'send' or
--    the writes for control messages).
--
-- Of course, "serialize" does not mean that we want for the remote endpoint to
-- reply. "Send" takes the mvar, sends to the endpoint (asynchronously), and
-- then puts the mvar back, without waiting for the endpoint to receive the
-- message. Similarly, when requesting a new connection, we take the mvar,
-- tentatively increment the reference count, send the control request, and
-- then put the mvar back. When the remote host responds to the new connection
-- request we might have to do another state change (reduce the refcount) if
-- the connection request was refused but we don't want to increment the ref
-- count only after the remote host acknowledges the request because then a
-- concurrent 'close' might actually attempt to close the socket.
-- 
-- Since we don't do concurrent reads from the same socket we don't need to
-- take the lock when reading from the socket.
--
-- Moreover, we insist on the invariant (INV-CLOSE) that whenever we put an
-- endpoint in closed state we remove that endpoint from localConnections
-- first, so that if a concurrent thread reads the mvar, finds EndPointClosed,
-- and then looks up the endpoint in localConnections it is guaranteed to
-- either find a different remote endpoint, or else none at all.

data RemoteEndPoint = RemoteEndPoint 
  { remoteAddress :: EndPointAddress
  , remoteState   :: MVar RemoteState
  }

data RemoteState =
    RemoteEndPointInvalid (TransportError ConnectErrorCode)
  | RemoteEndPointValid ValidRemoteEndPointState 
  | RemoteEndPointClosing (MVar ()) ValidRemoteEndPointState 
  | RemoteEndPointClosed

data ValidRemoteEndPointState = ValidRemoteEndPointState 
  { _remoteOutgoing :: !Int
  , _remoteIncoming :: IntSet
  ,  remoteSocket   :: N.Socket
  ,  sendOn         :: [ByteString] -> IO ()
  }

type EndPointId       = Int32
type ControlRequestId = Int32
type EndPointPair     = (LocalEndPoint, RemoteEndPoint)

-- | Control headers 
data ControlHeader = 
    RequestConnectionId -- ^ Request a new connection ID from the remote endpoint
  | CloseConnection     -- ^ Tell the remote endpoint we will no longer be using a connection
  | ControlResponse     -- ^ Respond to a control request /from/ the remote endpoint
  | CloseSocket         -- ^ Request to close the connection (see module description)
  deriving (Enum, Bounded, Show)

-- Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    ConnectionRequestAccepted        -- ^ /B/ accepts the connection
  | ConnectionRequestEndPointInvalid -- ^ /A/ requested an invalid endpoint
  | ConnectionRequestCrossed         -- ^ /A/s request crossed with a request from /B/ (see protocols)
  deriving (Enum, Bounded, Show)

--------------------------------------------------------------------------------
-- Top-level functionality                                                    --
--------------------------------------------------------------------------------

-- | Create a TCP transport
--
-- TODOs: deal with hints
createTransport :: N.HostName -> N.ServiceName -> IO (Either IOException Transport)
createTransport host port = do 
    state <- newMVar . TransportValid $ ValidTransportState { _localEndPoints = Map.empty }
    let transport = TCPTransport { transportState = state
                                 , transportHost  = host
                                 , transportPort  = port
                                 }
    tryIO $ do 
      -- For a discussion of the use of N.sOMAXCONN, see
      -- http://tangentsoft.net/wskfaq/advanced.html#backlog
      -- http://www.linuxjournal.com/files/linuxjournal.com/linuxjournal/articles/023/2333/2333s2.html
      transportThread <- forkServer host port N.sOMAXCONN (terminationHandler transport) (handleConnectionRequest transport) 
      return Transport { newEndPoint    = apiNewEndPoint transport 
                       , closeTransport = killThread transportThread -- This will invoke the termination handler
                       } 
  where
    terminationHandler :: TCPTransport -> SomeException -> IO ()
    terminationHandler transport _ = do
      -- TODO: we currently don't make a distinction between endpoint failure and manual closure
      mTSt <- modifyMVar (transportState transport) $ \st -> case st of
        TransportValid vst -> return (TransportClosed, Just vst)
        TransportClosed    -> return (TransportClosed, Nothing)
      case mTSt of
        Nothing ->
          -- Transport already closed
          return ()
        Just tSt ->
          mapM_ (apiCloseEndPoint transport) (Map.elems $ tSt ^. localEndPoints)

--------------------------------------------------------------------------------
-- API functions                                                              --
--------------------------------------------------------------------------------

-- | Create a new endpoint 
apiNewEndPoint :: TCPTransport -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint transport = try $ do
  ourEndPoint <- createLocalEndPoint transport
  return EndPoint 
    { receive       = readChan (localChannel ourEndPoint)
    , address       = localAddress ourEndPoint
    , connect       = apiConnect ourEndPoint 
    , closeEndPoint = apiCloseEndPoint transport ourEndPoint
    , newMulticastGroup     = return . Left $ newMulticastGroupError 
    , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
    }
  where
    newMulticastGroupError     = TransportError NewMulticastGroupUnsupported "TCP does not support multicast" 
    resolveMulticastGroupError = TransportError ResolveMulticastGroupUnsupported "TCP does not support multicast" 

-- | Connnect to an endpoint
apiConnect :: LocalEndPoint    -- ^ Local end point
           -> EndPointAddress  -- ^ Remote address
           -> Reliability      -- ^ Reliability (ignored)
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect ourEndPoint theirAddress _ | localAddress ourEndPoint == theirAddress = 
  connectToSelf ourEndPoint 
apiConnect ourEndPoint theirAddress _ = try $ do 
  (theirEndPoint, connId) <- requestConnectionTo ourEndPoint theirAddress
  -- connAlive can be an IORef rather than an MVar because it is protected by
  -- the remoteState MVar. We don't need the overhead of locking twice.
  connAlive <- newIORef True
  return $ Connection { send  = apiSend  theirEndPoint connId connAlive 
                      , close = apiClose theirEndPoint connId connAlive 
                      }

-- | Close a connection
--
-- RELY: Remote endpoint must be in 'RemoteEndPointValid' or 'RemoteEndPointClosed' 
-- GUARANTEE: If the connection is alive on entry then the remote endpoint will
--   either be RemoteEndPointValid or RemoteEndPointClosing. Otherwise, the state
--   of the remote endpoint will not be changed. 
--
-- TODO: We ignore errors during a close. Is that right? 
apiClose :: RemoteEndPoint -> ConnectionId -> IORef Bool -> IO ()
apiClose theirEndPoint connId connAlive = void . tryIO $ do 
  modifyMVar_ (remoteState theirEndPoint) $ \st -> case st of
    RemoteEndPointValid vst -> do
      alive <- readIORef connAlive
      if alive 
        then do
          writeIORef connAlive False
          sendOn vst [encodeInt32 CloseConnection, encodeInt32 connId] 
          return (RemoteEndPointValid . (remoteOutgoing ^: (\x -> x - 1)) $ vst)
        else
          return (RemoteEndPointValid vst)
    RemoteEndPointClosed -> do
      return st 
    RemoteEndPointClosing _ _ ->
      fail "apiClose RELY violation"
    RemoteEndPointInvalid _ ->
      fail "apiClose RELY violation"
  closeIfUnused theirEndPoint

-- | Send data across a connection
-- 
-- RELY: The remote endpoint must be in state 'RemoteEndPointValid' or 'RemoteEndPointClosed'
-- GUARANTEE: The state of the remote endpoint will not be changed.
apiSend :: RemoteEndPoint -> ConnectionId -> IORef Bool -> [ByteString] -> IO (Either (TransportError SendErrorCode) ())
apiSend theirEndPoint connId connAlive payload = do 
    withMVar (remoteState theirEndPoint) $ \st -> case st of
      RemoteEndPointValid vst -> do
        alive <- readIORef connAlive
        try $ if alive 
          then mapExceptionIO sendFailed $ sendOn vst (encodeInt32 connId : prependLength payload)
          else throw $ TransportError SendFailed "Connection closed" 
      RemoteEndPointClosed -> do
        return (Left $ TransportError SendFailed "Endpoint closed")
      RemoteEndPointClosing _ _ ->
        error "apiSend RELY violation"
      RemoteEndPointInvalid _ ->
        error "apiSend RELY violation"
  where
    sendFailed :: IOException -> TransportError SendErrorCode
    sendFailed = TransportError SendFailed . show

-- | Force-close the endpoint
apiCloseEndPoint :: TCPTransport -> LocalEndPoint -> IO ()
apiCloseEndPoint transport ourEndPoint = do
  -- Remove the reference from the transport state
  removeLocalEndPoint transport ourEndPoint
  -- Close the local endpoint 
  mOurState <- modifyMVar (localState ourEndPoint) $ \st ->
    case st of
      LocalEndPointValid vst -> 
        return (LocalEndPointClosed, Just vst)
      LocalEndPointClosed ->
        return (LocalEndPointClosed, Nothing)
  case mOurState of
    Nothing -> -- Already closed
      return ()
    Just vst -> do
      -- Close all endpoints and kill all threads  
      forM_ (Map.elems $ vst ^. localConnections) $ tryCloseRemoteSocket
      forM_ (vst ^. internalThreads) killThread
      -- We send a single message to the endpoint that it is closed. Subsequent
      -- calls will block. We could change this so that all subsequent calls to
      -- receive return an error, but this would mean checking for some state on
      -- every call to receive, which is an unnecessary overhead.  
      writeChan (localChannel ourEndPoint) EndPointClosed 
  where
    -- Close the remote socket and return the set of all incoming connections
    tryCloseRemoteSocket :: RemoteEndPoint -> IO () 
    tryCloseRemoteSocket theirEndPoint = do
      -- We make an attempt to close the connection nicely (by sending a CloseSocket first)
      modifyMVar_ (remoteState theirEndPoint) $ \st ->
        case st of
          RemoteEndPointInvalid _ -> 
            return st
          RemoteEndPointValid conn -> do 
            -- Try to send a CloseSocket request
            tryIO $ sendOn conn [encodeInt32 CloseSocket]
            -- .. but even if it fails, close the socket anyway 
            -- (hence, two separate calls to tryIO)
            tryIO $ N.sClose (remoteSocket conn)
            return RemoteEndPointClosed
          RemoteEndPointClosing _ conn -> do 
            tryIO $ N.sClose (remoteSocket conn)
            return RemoteEndPointClosed
          RemoteEndPointClosed -> 
            return RemoteEndPointClosed

-- | Special case of 'apiConnect': connect an endpoint to itself
connectToSelf :: LocalEndPoint -> IO (Either (TransportError ConnectErrorCode) Connection)
connectToSelf ourEndPoint = do
    -- Here connAlive must an MVar because it is not protected by another lock
    connAlive <- newMVar True 
    -- TODO: catch exception
    connId    <- getNextConnectionId ourEndPoint 
    writeChan ourChan (ConnectionOpened connId ReliableOrdered (localAddress ourEndPoint))
    return . Right $ Connection { send  = selfSend connAlive connId 
                                , close = selfClose connAlive connId
                                }
  where
    ourChan :: Chan Event
    ourChan = localChannel ourEndPoint

    selfSend :: MVar Bool -> ConnectionId -> [ByteString] -> IO (Either (TransportError SendErrorCode) ())
    selfSend connAlive connId msg = do
      modifyMVar connAlive $ \alive ->
        if alive
          then do 
            writeChan ourChan (Received connId msg)
            return (alive, Right ())
          else 
            return (alive, Left (TransportError SendFailed "Connection closed"))

    selfClose :: MVar Bool -> ConnectionId -> IO ()
    selfClose connAlive connId = do
      modifyMVar_ connAlive $ \alive -> do
        when alive $ writeChan ourChan (ConnectionClosed connId) 
        return False

--------------------------------------------------------------------------------
-- Lower level functionality                                                  --
--------------------------------------------------------------------------------

-- | Create a new local endpoint
-- 
-- May throw a TransportError NewEndPointErrorCode exception if the transport is closed.
createLocalEndPoint :: TCPTransport -> IO LocalEndPoint
createLocalEndPoint transport = do 
    chan  <- newChan
    state <- newMVar . LocalEndPointValid $ ValidLocalEndPointState 
      { _nextConnectionId    = firstNonReservedConnectionId 
      , _pendingCtrlRequests = IntMap.empty
      , _nextCtrlRequestId   = 0
      , _localConnections    = Map.empty
      , _internalThreads     = []
      }
    modifyMVar (transportState transport) $ \st -> case st of
      TransportValid vst -> do
        let ix   = fromIntegral $ Map.size (vst ^. localEndPoints) 
        let addr = encodeEndPointAddress (transportHost transport) (transportPort transport) ix 
        let localEndPoint = LocalEndPoint { localAddress  = addr
                                          , localChannel  = chan
                                          , localState    = state
                                          }
        return (TransportValid . (localEndPointAt addr ^= Just localEndPoint) $ vst, localEndPoint)
      TransportClosed ->
        throw (TransportError NewEndPointFailed "Transport closed")

-- | Request a connection to a remote endpoint
--
-- This will block until we get a connection ID from the remote endpoint; if
-- the remote endpoint was in 'RemoteEndPointClosing' state then we will
-- additionally block until that is resolved. 
--
-- May throw a TransportError ConnectErrorCode exception.
requestConnectionTo :: LocalEndPoint 
                    -> EndPointAddress 
                    -> IO (RemoteEndPoint, ConnectionId)
requestConnectionTo ourEndPoint theirAddress = go
  where
    go = do
      -- Find the remote endpoint (create it if it doesn't yet exist)
      theirEndPoint <- findTheirEndPoint
      let theirState = remoteState theirEndPoint
  
      -- Before we initiate the new connection request we want to make sure that
      -- refcount on the endpoint is incremented so that a concurrent thread will
      -- not close the connection. Note that if IF we return RemoteEndPointValid
      -- here then we can rely on the endpoint remaining in that state. 
      endPointStateSnapshot <- modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointValid ep ->
            return (RemoteEndPointValid . (remoteOutgoing ^: (+ 1)) $ ep, st)
          _ ->
            return (st, st)
  
      -- From this point on we are guaranteed the refcount is positive, provided
      -- that the endpoint was valid. We still need to deal with the case where
      -- it was not valid, however, which we didn't want to do while holding the
      -- endpoint lock. 
      --
      -- Although 'endPointStateSnapshot' here refers to a snapshot of the
      -- endpoint state, and might have changed in the meantime, these changes
      -- won't matter.
      case endPointStateSnapshot of
        RemoteEndPointInvalid err -> do
          throw err
      
        RemoteEndPointClosing resolved _ -> 
          -- If the remote endpoint is closing, then we need to block until
          -- this is resolved and we then try again
          readMVar resolved >> go
  
        RemoteEndPointClosed -> do
          -- EndPointClosed indicates that a concurrent thread was in the
          -- process of closing the TCP connection to the remote endpoint when
          -- we obtained a reference to it. The remote endpoint will now have
          -- been removed from ourState, so we simply try again.
          go 
     
        RemoteEndPointValid _ -> do
          -- On a failure we decrement the refcount again and return an error.
          -- The only state the remote endpoint can be in at this point is
          -- valid. As mentioned above, we can rely on the endpoint being in
          -- valid state at this point.
          let failureHandler :: IOException -> IO b 
              failureHandler err = do
                modifyMVar_ theirState $ \(RemoteEndPointValid ep) -> 
                  return (RemoteEndPointValid . (remoteOutgoing ^: (\x -> x - 1)) $ ep)
                -- TODO: should we call closeIfUnused here?
                throw $ TransportError ConnectFailed (show err) 
  
          -- Do the actual connection request. This blocks until the remote
          -- endpoint replies (but note that we don't hold any locks at this
          -- point)
          reply <- handle failureHandler $ doRemoteRequest (ourEndPoint, theirEndPoint) RequestConnectionId 
          case decodeInt32 . BS.concat $ reply of
            Nothing  -> failureHandler (userError "Invalid integer")
            Just cid -> return (theirEndPoint, cid) 

    -- If this is a new endpoint, fork a thread to listen for incoming
    -- connections. We don't want to do this while we hold the lock, because
    -- forkEndPointThread modifies the local state too (to record the thread
    -- ID)
    findTheirEndPoint :: IO RemoteEndPoint
    findTheirEndPoint = do
      (theirEndPoint, isNew) <- modifyMVar ourState $ \st -> case st of
        LocalEndPointClosed ->
          throw (TransportError ConnectFailed "Local endpoint closed")
        LocalEndPointValid vst ->
          case vst ^. localConnectionTo theirAddress of
            Just theirEndPoint ->
              return (st, (theirEndPoint, False))
            Nothing -> do
              theirState <- newEmptyMVar
              let theirEndPoint = RemoteEndPoint { remoteAddress = theirAddress
                                                 , remoteState   = theirState
                                                 }
              return (LocalEndPointValid . (localConnectionTo theirAddress ^= Just theirEndPoint) $ vst, (theirEndPoint, True))
      
      -- The only way for forkEndPointThread to fail is if the local endpoint
      -- gets closed. This error will be caught elsewhere, so we ignore it
      -- here.
      when isNew . void . forkEndPointThread ourEndPoint $  
        setupRemoteEndPoint (ourEndPoint, theirEndPoint)
      return theirEndPoint

    ourState :: MVar LocalEndPointState
    ourState = localState ourEndPoint

-- | Set up a remote endpoint
-- 
-- RELY: The state of the remote endpoint must be uninitialized.
-- GUARANTEE: Will only change the state to RemoteEndPointValid or
--   RemoteEndPointInvalid. 
setupRemoteEndPoint :: EndPointPair -> IO ()
setupRemoteEndPoint (ourEndPoint, theirEndPoint) = do
    result <- socketToEndPoint (localAddress ourEndPoint) (remoteAddress theirEndPoint)
    case result of
      Right (sock, ConnectionRequestAccepted) -> do 
        let vst = ValidRemoteEndPointState 
                    {  remoteSocket   = sock
                    , _remoteOutgoing = 0
                    , _remoteIncoming = IntSet.empty
                    ,  sendOn         = sendMany sock 
                    }
        putMVar theirState (RemoteEndPointValid vst)
        handleIncomingMessages (ourEndPoint, theirEndPoint)
      Right (sock, ConnectionRequestEndPointInvalid) -> do
        -- We remove the endpoint from our local state again because the next
        -- call to 'connect' might give a different result. Threads that were
        -- waiting on the result of this call to connect will get the
        -- RemoteEndPointInvalid; subsequent threads will initiate a new
        -- connection requests. 
        removeRemoteEndPoint (ourEndPoint, theirEndPoint)
        putMVar theirState (RemoteEndPointInvalid (invalidAddress "Invalid endpoint"))
        N.sClose sock
      Right (sock, ConnectionRequestCrossed) -> do
        N.sClose sock
      Left err -> do 
        -- See comment above 
        removeRemoteEndPoint (ourEndPoint, theirEndPoint)
        putMVar theirState (RemoteEndPointInvalid err)
  where
    theirState      = remoteState theirEndPoint
    invalidAddress  = TransportError ConnectNotFound

-- | Establish a connection to a remote endpoint
socketToEndPoint :: EndPointAddress -- ^ Our address 
                 -> EndPointAddress -- ^ Their address
                 -> IO (Either (TransportError ConnectErrorCode) (N.Socket, ConnectionRequestResponse)) 
socketToEndPoint (EndPointAddress ourAddress) theirAddress = try $ do 
    (host, port, theirEndPointId) <- case decodeEndPointAddress theirAddress of 
      Nothing  -> throw (failed . userError $ "Could not parse")
      Just dec -> return dec
    addr:_ <- mapExceptionIO invalidAddress $ N.getAddrInfo Nothing (Just host) (Just port)
    bracketOnError (createSocket addr) N.sClose $ \sock -> do
      mapExceptionIO failed $ N.setSocketOption sock N.ReuseAddr 1
      mapExceptionIO invalidAddress $ N.connect sock (N.addrAddress addr) 
      response <- mapExceptionIO failed $ do
        sendMany sock (encodeInt32 theirEndPointId : prependLength [ourAddress]) 
        recvInt32 sock
      case tryToEnum response of
        Nothing -> throw (failed . userError $ "Unexpected response")
        Just r  -> return (sock, r)
  where
    createSocket :: N.AddrInfo -> IO N.Socket
    createSocket addr = mapExceptionIO insufficientResources $ do
      sock <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      -- putStrLn $ "Created client socket " ++ show sock
      return sock

    invalidAddress, insufficientResources, failed :: IOException -> TransportError ConnectErrorCode
    invalidAddress        = TransportError ConnectNotFound . show 
    insufficientResources = TransportError ConnectInsufficientResources . show 
    failed                = TransportError ConnectFailed . show

-- | Remove reference to a remote endpoint from a local endpoint
--
-- If the local endpoint is closed, do nothing
removeRemoteEndPoint :: EndPointPair -> IO ()
removeRemoteEndPoint (ourEndPoint, theirEndPoint) = do
  modifyMVar_ (localState ourEndPoint) $ \st -> case st of
    LocalEndPointValid vst ->
      return (LocalEndPointValid . (localConnectionTo (remoteAddress theirEndPoint) ^= Nothing) $ vst)
    LocalEndPointClosed ->
      return LocalEndPointClosed

-- | Remove reference to a local endpoint from the transport state
--
-- Does nothing if the transport is closed
removeLocalEndPoint :: TCPTransport -> LocalEndPoint -> IO ()
removeLocalEndPoint transport ourEndPoint = do
  modifyMVar_ (transportState transport) $ \st -> case st of 
    TransportValid vst ->
      return (TransportValid . (localEndPointAt (localAddress ourEndPoint) ^= Nothing) $ vst)
    TransportClosed ->
      return TransportClosed

-- | Encode end point address
encodeEndPointAddress :: N.HostName -> N.ServiceName -> EndPointId -> EndPointAddress
encodeEndPointAddress host port ix = EndPointAddress . BSC.pack $
  host ++ ":" ++ port ++ ":" ++ show ix 

-- | Decode end point address
decodeEndPointAddress :: EndPointAddress -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) = case map BSC.unpack $ BSC.split ':' bs of
    [host, port, endPointIdStr] -> 
      case reads endPointIdStr of 
        [(endPointId, "")] -> Just (host, port, endPointId)
        _                  -> Nothing
    _ ->
      Nothing

-- | Do a (blocking) remote request 
-- 
-- RELY: Remote endpoint must be in valid state.
-- GUARANTEE: Will not change the state of the remote endpoint.
--
-- May throw IO (user) exception if the local endpoint is closed or if the send
-- fails.
doRemoteRequest :: EndPointPair -> ControlHeader -> IO [ByteString]
doRemoteRequest (ourEndPoint, theirEndPoint) header = do 
  reply <- newEmptyMVar
  reqId <- modifyMVar (localState ourEndPoint) $ \st -> case st of
    LocalEndPointValid vst -> do
      let reqId = vst ^. nextCtrlRequestId
      return (LocalEndPointValid . (nextCtrlRequestId ^: (+ 1)) . (pendingCtrlRequestsAt reqId ^= Just reply) $ vst, reqId)
    LocalEndPointClosed ->
      throw (userError "Local endpoint closed")
  withMVar (remoteState theirEndPoint) $ \(RemoteEndPointValid vst) ->
    sendOn vst [encodeInt32 header, encodeInt32 reqId]
  takeMVar reply 

-- | Check if the remote endpoint is unused, and if so, send a CloseSocket request
closeIfUnused :: RemoteEndPoint -> IO ()
closeIfUnused theirEndPoint = modifyMVar_ (remoteState theirEndPoint) $ \st -> 
  case st of
    RemoteEndPointValid vst -> do
      if vst ^. remoteOutgoing == 0 && IntSet.null (vst ^. remoteIncoming) 
        then do 
          resolved <- newEmptyMVar
          sendOn vst [encodeInt32 CloseSocket]
          return (RemoteEndPointClosing resolved vst)
        else 
          return st
    _ -> do
      return st

-- | Fork a new thread and store its ID as part of the transport state
-- 
-- If the local end point is closed this function does nothing (no thread is
-- spawned). Returns whether or not a thread was spawned.
forkEndPointThread :: LocalEndPoint -> IO () -> IO Bool 
forkEndPointThread ourEndPoint p = 
    modifyMVar ourState $ \st -> case st of
      LocalEndPointValid vst -> do
        tid <- forkIO (p >> removeThread) 
        return (LocalEndPointValid . (internalThreads ^: (tid :)) $ vst, True)
      LocalEndPointClosed ->
        return (LocalEndPointClosed, False)
  where
    removeThread :: IO ()
    removeThread = do
      tid <- myThreadId
      modifyMVar_ ourState $ \st -> case st of
        LocalEndPointValid vst ->
          return (LocalEndPointValid . (internalThreads ^: filter (/= tid)) $ vst)
        LocalEndPointClosed ->
          return LocalEndPointClosed

    ourState :: MVar LocalEndPointState
    ourState = localState ourEndPoint

--------------------------------------------------------------------------------
-- Incoming requests                                                          --
--------------------------------------------------------------------------------

-- | Handle a connection request (that is, a remote endpoint that is trying to
-- establish a TCP connection with us)
--
-- 'handleConnectionRequest' runs in the context of the transport thread, which
-- can be killed asynchronously by 'closeTransport'. We fork a separate thread
-- as soon as we have located the lcoal endpoint that the remote endpoint is
-- interested in. We cannot fork any sooner because then we have no way of
-- storing the thread ID and hence no way of killing the thread when we take
-- the transport down. We must be careful to close the socket when a (possibly
-- asynchronous, ThreadKilled) exception occurs. (If an exception escapes from
-- handleConnectionRequest the transport will be shut down.)
handleConnectionRequest :: TCPTransport -> N.Socket -> IO () 
handleConnectionRequest transport sock = handle tryCloseSocket $ do 
    ourEndPointId <- recvInt32 sock
    theirAddress  <- EndPointAddress . BS.concat <$> recvWithLength sock 
    let ourAddress = encodeEndPointAddress (transportHost transport) (transportPort transport) ourEndPointId
    ourEndPoint <- withMVar (transportState transport) $ \st -> case st of
      TransportValid vst ->
        case vst ^. localEndPointAt ourAddress of
          Nothing -> do
            sendMany sock [encodeInt32 ConnectionRequestEndPointInvalid]
            fail "Invalid endpoint"
          Just ourEndPoint ->
            return ourEndPoint
      TransportClosed -> do
        fail "Transport closed"
    void . forkEndPointThread ourEndPoint $ go ourEndPoint theirAddress
  where
    go :: LocalEndPoint -> EndPointAddress -> IO ()
    go ourEndPoint theirAddress = do 
      mEndPoint <- handle (\e -> invalidEndPoint e >> return Nothing) $ do 
        (crossed, theirEndPoint) <- modifyMVar (localState ourEndPoint) $ \st -> case st of
          LocalEndPointValid vst -> 
            case vst ^. localConnectionTo theirAddress of
              Nothing -> do
                theirState <- newEmptyMVar
                let theirEndPoint = RemoteEndPoint { remoteAddress = theirAddress
                                                   , remoteState   = theirState
                                                   }
                return (LocalEndPointValid . (localConnectionTo theirAddress ^= Just theirEndPoint) $ vst, (False, theirEndPoint))
              Just theirEndPoint -> 
                return (st, (localAddress ourEndPoint < theirAddress, theirEndPoint))
          LocalEndPointClosed ->
            fail "Local endpoint closed"
        if crossed 
          then do
            tryIO $ sendMany sock [encodeInt32 ConnectionRequestCrossed]
            tryIO $ N.sClose sock
            return Nothing 
          else do
            let vst = ValidRemoteEndPointState 
                        {  remoteSocket   = sock
                        , _remoteOutgoing = 0
                        , _remoteIncoming = IntSet.empty
                        , sendOn          = sendMany sock
                        }
            -- TODO: this putMVar might block if the remote endpoint sends a
            -- connection request for a local endpoint that it is already
            -- connected to
            putMVar (remoteState theirEndPoint) (RemoteEndPointValid vst)
            sendMany sock [encodeInt32 ConnectionRequestAccepted]
            return (Just theirEndPoint)
      -- If we left the scope of the exception handler with a return value of
      -- Nothing then the socket is already closed; otherwise, the socket has
      -- been recorded as part of the remote endpoint. Either way, we no longer
      -- have to worry about closing the socket on receiving an asynchronous
      -- exception from this point forward. 
      case mEndPoint of
        Nothing -> 
          return ()
        Just theirEndPoint ->
          handleIncomingMessages (ourEndPoint, theirEndPoint)

    tryCloseSocket :: IOException -> IO () 
    tryCloseSocket _ = void . tryIO $ N.sClose sock

    invalidEndPoint :: IOException -> IO () 
    invalidEndPoint ex = do
      tryIO $ sendMany sock [encodeInt32 ConnectionRequestEndPointInvalid]
      tryCloseSocket ex

-- | Handle requests from a remote endpoint.
-- 
-- Returns only if the remote party closes the socket or if an error occurs.
--
-- RELY: The remote endpoint must be in RemoteEndPointValid or
--   RemoteEndPointClosing state. If the latter, then the 'resolved' MVar
--   associated with the closing state must be empty.
-- GUARANTEE: May change the remote endpoint to RemoteEndPointClosed state. 
handleIncomingMessages :: EndPointPair -> IO () 
handleIncomingMessages (ourEndPoint, theirEndPoint) = do
    -- For efficiency sake we get the socket once and for all
    sock <- withMVar theirState $ \st ->
      case st of
        RemoteEndPointValid ep ->
          return (remoteSocket ep)
        RemoteEndPointClosing _ ep ->
          return (remoteSocket ep)
        _ ->
          error "handleIncomingMessages RELY violation"
  
    mCleanExit <- tryIO $ go sock
    case mCleanExit of
      Right () -> return ()
      Left err -> prematureExit sock err
  where
    -- Dispatch 
    go :: N.Socket -> IO ()
    go sock = do
      connId <- recvInt32 sock 
      if connId >= firstNonReservedConnectionId 
        then do
          readMessage sock connId
          go sock
        else do 
          case tryToEnum (fromIntegral connId) of
            Just RequestConnectionId -> do
              recvInt32 sock >>= createNewConnection 
              go sock 
            Just ControlResponse -> do 
              recvInt32 sock >>= readControlResponse sock 
              go sock
            Just CloseConnection -> do
              recvInt32 sock >>= closeConnection 
              go sock
            Just CloseSocket -> do 
              didClose <- closeSocket sock 
              unless didClose $ go sock
            Nothing ->
              -- Invalid control request, exit
              hPutStrLn stderr "Warning: invalid control request"
        
    -- Create a new connection
    createNewConnection :: ControlRequestId -> IO () 
    createNewConnection reqId = do 
      newId <- getNextConnectionId ourEndPoint
      modifyMVar_ theirState $ \st -> do
        vst <- case st of
          RemoteEndPointValid vst ->
            return (remoteIncoming ^: IntSet.insert newId $ vst)
          RemoteEndPointClosing resolved vst -> do
            -- If the endpoint is in closing state that means we send a
            -- CloseSocket request to the remote endpoint. If the remote
            -- endpoint replies with the request to create a new connection, it
            -- either ignored our request or it sent the request before it got
            -- ours.  Either way, at this point we simply restore the endpoint
            -- to RemoteEndPointValid
            putMVar resolved ()
            return (remoteIncoming ^= IntSet.singleton newId $ vst)
          _ ->
            error "handleIncomingMessages RELY violation"
        sendOn vst ( encodeInt32 ControlResponse 
                          : encodeInt32 reqId 
                          : prependLength [encodeInt32 newId] 
                          )
        -- We add the new connection ID to the list of open connections only once the
        -- endpoint has been notified of the new connection (sendOn may fail)
        return (RemoteEndPointValid vst)
      writeChan ourChannel (ConnectionOpened newId ReliableOrdered theirAddr) 

    -- Read a control response 
    readControlResponse :: N.Socket -> ControlRequestId -> IO () 
    readControlResponse sock reqId = do
      response <- recvWithLength sock
      mmvar    <- modifyMVar ourState $ \st -> case st of
        LocalEndPointValid vst ->
          return (LocalEndPointValid . (pendingCtrlRequestsAt reqId ^= Nothing) $ vst, vst ^. pendingCtrlRequestsAt reqId)
        LocalEndPointClosed ->
          fail "Local endpoint closed"
      case mmvar of
        Nothing -> do 
          hPutStrLn stderr $ "Warning: Invalid request ID"
          return () -- Invalid request ID. TODO: We just ignore it?
        Just mvar -> 
          putMVar mvar response

    -- Close a connection 
    closeConnection :: ConnectionId -> IO () 
    closeConnection cid = do
      -- TODO: we should check that this connection is in fact open 
      writeChan ourChannel (ConnectionClosed cid)
      modifyMVar_ theirState $ \(RemoteEndPointValid vst) ->
        return (RemoteEndPointValid . (remoteIncoming ^: IntSet.delete cid) $ vst)
      closeIfUnused theirEndPoint

    -- Close the socket (if we don't have any outgoing connections)
    closeSocket :: N.Socket -> IO Bool 
    closeSocket sock = do
      -- We need to check if we can close the socket (that is, if we don't have
      -- any outgoing connections), and once we are sure that we can put the
      -- endpoint in Closed state. However, by INV-CLOSE we can only put the
      -- endpoint in Closed state once we remove the endpoint from our local
      -- connections. But we can do that only once we are sure that we can
      -- close the endpoint. Catch-22. We can resolve the catch-22 by locking
      -- /both/ our local state and the endpoint state, but at the cost of
      -- introducing a double lock and all the associated perils, or by putting
      -- the remote endpoint in Closing state first. We opt for the latter. 
      canClose <- modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointValid vst -> do
            -- We regard a CloseSocket message as an (optimized) way for the
            -- remote endpoint to indicate that all its connections to us are
            -- now properly closed
            forM_ (IntSet.elems $ vst ^. remoteIncoming) $ \cid ->
              writeChan ourChannel (ConnectionClosed cid)
            let vst' = remoteIncoming ^= IntSet.empty $ vst 
            -- Check if we agree that the connection should be closed
            if vst' ^. remoteOutgoing == 0 
              then do 
                -- Attempt to reply (but don't insist)
                tryIO $ sendOn vst' [encodeInt32 CloseSocket]
                resolved <- newEmptyMVar 
                return (RemoteEndPointClosing resolved vst', Just resolved)
              else 
                return (RemoteEndPointValid vst', Nothing)
          RemoteEndPointClosing resolved _ ->
            return (st, Just resolved)
          _ ->
            error "handleIncomingConnections RELY violation"
      
      case canClose of
        Nothing ->
          return False
        Just resolved -> do
          removeRemoteEndPoint (ourEndPoint, theirEndPoint)
          modifyMVar_ theirState $ return . const RemoteEndPointClosed 
          N.sClose sock 
          putMVar resolved ()
          return True
            
    -- Read a message and output it on the endPoint's channel
    readMessage :: N.Socket -> ConnectionId -> IO () 
    readMessage sock connId = recvWithLength sock >>= writeChan ourChannel . Received connId

    -- Arguments
    ourChannel  = localChannel ourEndPoint 
    ourState    = localState ourEndPoint 
    theirState  = remoteState theirEndPoint
    theirAddr   = remoteAddress theirEndPoint

    -- Deal with a premature exit
    prematureExit :: N.Socket -> IOException -> IO ()
    prematureExit sock err = do
      N.sClose sock
      removeRemoteEndPoint (ourEndPoint, theirEndPoint)
      mUnclosedConnections <- modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointInvalid _ ->
            error "handleIncomingMessages RELY violation"
          RemoteEndPointValid vst ->
            return (RemoteEndPointClosed, Just $ vst ^. remoteIncoming)
          RemoteEndPointClosing _ _ ->
            return (RemoteEndPointClosed, Nothing)
          RemoteEndPointClosed ->
            return (st, Nothing)
   
      -- We send the connection lost message even if unclosedConnections is the
      -- empty set, because *outgoing* connections will be broken too  now
      case mUnclosedConnections of
        Nothing -> 
          return ()
        Just unclosedConnections -> writeChan ourChannel . ErrorEvent $ 
          TransportError (EventConnectionLost (remoteAddress theirEndPoint) (IntSet.elems unclosedConnections)) (show err) 

-- | Get the next connection ID
-- 
-- Throws an IO exception when the endpoint is closed.
getNextConnectionId :: LocalEndPoint -> IO ConnectionId
getNextConnectionId ourEndpoint = 
  modifyMVar (localState ourEndpoint) $ \st -> case st of
    LocalEndPointValid vst -> do
      let connId = vst ^. nextConnectionId 
      return (LocalEndPointValid . (nextConnectionId ^= connId + 1) $ vst, connId)
    LocalEndPointClosed ->
      fail "Local endpoint closed"

--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

-- | We reserve a bunch of connection IDs for control messages
firstNonReservedConnectionId :: ConnectionId
firstNonReservedConnectionId = 1024

--------------------------------------------------------------------------------
-- Accessor definitions                                                           --
--------------------------------------------------------------------------------

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\es st -> st { _localEndPoints = es })

pendingCtrlRequests :: Accessor ValidLocalEndPointState (IntMap (MVar [ByteString]))
pendingCtrlRequests = accessor _pendingCtrlRequests (\rep st -> st { _pendingCtrlRequests = rep })

nextCtrlRequestId :: Accessor ValidLocalEndPointState ControlRequestId 
nextCtrlRequestId = accessor _nextCtrlRequestId (\cid st -> st { _nextCtrlRequestId = cid })

nextConnectionId :: Accessor ValidLocalEndPointState ConnectionId
nextConnectionId = accessor _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

localConnections :: Accessor ValidLocalEndPointState (Map EndPointAddress RemoteEndPoint)
localConnections = accessor _localConnections (\es st -> st { _localConnections = es })

internalThreads :: Accessor ValidLocalEndPointState [ThreadId]
internalThreads = accessor _internalThreads (\ts st -> st { _internalThreads = ts })

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr 

pendingCtrlRequestsAt :: ControlRequestId -> Accessor ValidLocalEndPointState (Maybe (MVar [ByteString]))
pendingCtrlRequestsAt ix = pendingCtrlRequests >>> DAC.intMapMaybe (fromIntegral ix)

localConnectionTo :: EndPointAddress -> Accessor ValidLocalEndPointState (Maybe RemoteEndPoint)
localConnectionTo addr = localConnections >>> DAC.mapMaybe addr 

remoteOutgoing :: Accessor ValidRemoteEndPointState Int
remoteOutgoing = accessor _remoteOutgoing (\cs conn -> conn { _remoteOutgoing = cs })

remoteIncoming :: Accessor ValidRemoteEndPointState IntSet
remoteIncoming = accessor _remoteIncoming (\cs conn -> conn { _remoteIncoming = cs })
