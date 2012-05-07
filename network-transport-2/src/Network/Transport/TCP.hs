-- | TCP implementation of the transport layer. 
-- 
-- The TCP implementation guarantees that only a single TCP connection (socket)
-- will be used between endpoints, provided that the addresses specified are
-- canonical. If /A/ connects to /B/ and reports its address as
-- @192.168.0.1:8080@ and /B/ subsequently connects tries to connect to /A/ as
-- @client1.local:http-alt@ then the transport layer will not realize that the
-- TCP connection can be reused. 
module Network.Transport.TCP ( -- * Main API
                               createTransport
                             , -- * TCP specific functionality
                               EndPointId
                             , decodeEndPointAddress
                             , ControlHeader(..)
                             , ConnectionRequestResponse(..)
                             , firstNonReservedConnectionId
                               -- * Design notes
                               -- $design
                             ) where

import Network.Transport
import Network.Transport.Internal.TCP ( forkServer
                                      , recvWithLength
                                      , recvInt32
                                      )
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
                                  , prependLength
                                  , failWith
                                  , failWithIO
                                  , tryIO
                                  , tryToEnum
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
                                     )
import Network.Socket.ByteString (sendMany)
import Control.Concurrent (forkIO, ThreadId)
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
import Data.IORef (IORef, newIORef, writeIORef, readIORef, modifyIORef)
import Control.Category ((>>>))
import Control.Applicative ((<*>), (*>), (<$>))
import Control.Monad (forM_, void, when)
import Control.Monad.Error (ErrorT(ErrorT), runErrorT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (IOException)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Data.Int (Int32)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty, size)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet (empty, insert, delete, elems)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Lens.Lazy (Lens, lens, intMapLens, mapLens, (^.), (^=), (^+=))
import Text.Regex.Applicative (RE, few, anySym, sym, many, match)
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

data TCPTransport   = TCPTransport   { transportHost  :: N.HostName
                                     , transportPort  :: N.ServiceName
                                     , transportState :: MVar TransportState 
                                     }
data LocalEndPoint  = LocalEndPoint  { localAddress   :: EndPointAddress
                                     , localChannel   :: Chan Event
                                     , localState     :: MVar LocalState 
                                     }
data RemoteEndPoint = RemoteEndPoint { remoteAddress  :: EndPointAddress
                                     , remoteState    :: MVar RemoteState
                                     }

-- We use underscores for fields that we might update (using lenses).

data TransportState   = TransportState { _localEndPoints      :: IntMap LocalEndPoint }
data LocalState       = LocalState     { _nextConnectionId    :: ConnectionId 
                                       , _pendingCtrlRequests :: IntMap (MVar [ByteString])
                                       , _nextCtrlRequestId   :: ControlRequestId 
                                       , _localConnections    :: Map EndPointAddress RemoteEndPoint 
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
-- reply. "Send" takes the mvar, sends to the endpoint, and then puts the mvar
-- back, without waiting for the endpoint to receive the message. Similarly,
-- when requesting a new connection, we take the mvar, tentatively increment the
-- reference count, send the control request, and then put the mvar back. When
-- the remote host responds to the new connection request we might have to do
-- another state change (reduce the refcount) if the connection request was
-- refused but we don't want to increment the ref count only after the remote
-- host acknowledges the request because then a concurrent 'close' might
-- actually attempt to close the socket.
-- 
-- Since we don't do concurrent reads from the same socket we don't need to
-- take the lock when reading from the socket.

data RemoteState      = RemoteEndPointInvalid (FailedWith ConnectErrorCode)
                      | RemoteEndPointValid RemoteConnection
                      | RemoteEndPointClosing RemoteConnection (MVar ()) 
                      | RemoteEndPointClosed
data RemoteConnection = RemoteConnection { _remoteRefCount :: !Int
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
  | ControlResponse     -- ^ Respond to a control request _from_ the remote endpoint
  | CloseSocket         -- ^ Request to close the connection (see module description)
  deriving (Enum, Bounded)

-- Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    ConnectionRequestAccepted        -- ^ /B/ accepts the connection
  | ConnectionRequestEndPointInvalid -- ^ /A/ requested an invalid endpoint
  | ConnectionRequestCrossed         -- ^ /A/s request crossed with a request from /B/ (see protocols)
  deriving (Enum, Bounded)

--------------------------------------------------------------------------------
-- Top-level functionality                                                    --
--------------------------------------------------------------------------------

-- | Create a TCP transport
--
-- TODOs: deal with hints
createTransport :: N.HostName -> N.ServiceName -> IO (Either IOException Transport)
createTransport host port = do 
  state <- newMVar TransportState { _localEndPoints = IntMap.empty }
  let transport = TCPTransport    {  transportState = state
                                  ,  transportHost  = host
                                  ,  transportPort  = port
                                  }
  tryIO $ do 
    forkServer host port $ void . handleConnectionRequest transport
    return Transport { newEndPoint = apiNewEndPoint transport } 

--------------------------------------------------------------------------------
-- API functions                                                              --
--------------------------------------------------------------------------------

-- | Create a new endpoint 
apiNewEndPoint :: TCPTransport -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
apiNewEndPoint transport = do 
  ourEndPoint <- createLocalEndPoint transport
  return . Right $ EndPoint { receive = readChan (localChannel ourEndPoint)
                            , address = localAddress ourEndPoint
                            , connect = apiConnect ourEndPoint 
                            , newMulticastGroup     = return . Left $ newMulticastGroupError 
                            , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
                            }
  where
    newMulticastGroupError     = FailedWith NewMulticastGroupUnsupported "TCP does not support multicast" 
    resolveMulticastGroupError = FailedWith ResolveMulticastGroupUnsupported "TCP does not support multicast" 

-- | Connnect to an endpoint
apiConnect :: LocalEndPoint    -- ^ Local end point
           -> EndPointAddress  -- ^ Remote address
           -> Reliability      -- ^ Reliability (ignored)
           -> IO (Either (FailedWith ConnectErrorCode) Connection)
apiConnect ourEndPoint theirAddress _ | localAddress ourEndPoint == theirAddress = 
  connectToSelf ourEndPoint 
apiConnect ourEndPoint theirAddress _ = runErrorT $ do 
  (theirEndPoint, connId) <- requestConnectionTo ourEndPoint theirAddress
  -- connAlive can be an IORef rather than an MVar because it is protected by
  -- the remoteState MVar. We don't need the overhead of locking twice.
  connAlive <- liftIO $ newIORef True
  return $ Connection { send  = apiSend  theirEndPoint connId connAlive 
                      , close = apiClose theirEndPoint connId connAlive 
                      }

-- | Close a connection
--
-- RELY: If the connection is alive on entry then the remote endpoint must
--   remain in the state 'RemoteEndPointValid'.
-- GUARANTEE: If the connection is alive on entry then the remote endpoint will
--   either be RemoteEndPointValid or RemoteEndPointClosing. Otherwise, the state
--   of the remote endpoint will not be changed. 
--
-- TODO: We ignore errors during a close. Is that right? 
apiClose :: RemoteEndPoint -> ConnectionId -> IORef Bool -> IO ()
apiClose theirEndPoint connId connAlive = void . tryIO $ do 
  wasAlive <- withMVar (remoteState theirEndPoint) $ \(RemoteEndPointValid remoteConn) -> do 
    alive <- readIORef connAlive
    when alive $ do
      sendOn remoteConn [encodeInt32 CloseConnection, encodeInt32 connId] 
      writeIORef connAlive False
    return alive
  -- We don't want to call decreaseRemoteRefCount while we still hold the lock
  when wasAlive $ decreaseRemoteRefCount theirEndPoint

-- | Send data across a connection
-- 
-- RELY: The remote endpoint must remain in state 'RemoteEndPointValid'.
-- GUARANTEE: The state of the remote endpoint will not be changed.
apiSend :: RemoteEndPoint -> ConnectionId -> IORef Bool -> [ByteString] -> IO (Either (FailedWith SendErrorCode) ())
apiSend theirEndPoint connId connAlive payload = do 
  withMVar (remoteState theirEndPoint) $ \(RemoteEndPointValid remoteConn) -> do  
    alive <- readIORef connAlive
    runErrorT $ if alive
      then 
        failWithIO (FailedWith SendFailed . show) $ 
          sendOn remoteConn (encodeInt32 connId : prependLength payload)
      else 
        throwError $ FailedWith SendConnectionClosed "Connection closed"

-- | Special case of 'apiConnect': connect an endpoint to itself
connectToSelf :: LocalEndPoint -> IO (Either (FailedWith ConnectErrorCode) Connection)
connectToSelf ourEndPoint = do
    -- Here connAlive must an MVar because it is not protected by another lock
    connAlive <- newMVar True 
    connId    <- getNextConnectionId ourEndPoint 
    writeChan ourChan (ConnectionOpened connId ReliableOrdered (localAddress ourEndPoint))
    return . Right $ Connection { send  = selfSend connAlive connId 
                                , close = selfClose connAlive connId
                                }
  where
    ourChan :: Chan Event
    ourChan = localChannel ourEndPoint

    selfSend :: MVar Bool -> ConnectionId -> [ByteString] -> IO (Either (FailedWith SendErrorCode) ())
    selfSend connAlive connId msg = do
      modifyMVar connAlive $ \alive ->
        if alive
          then do 
            writeChan ourChan (Received connId msg)
            return (alive, Right ())
          else 
            return (alive, Left (FailedWith SendConnectionClosed "Connection closed"))

    selfClose :: MVar Bool -> ConnectionId -> IO ()
    selfClose connAlive connId = do
      modifyMVar_ connAlive $ \alive -> do
        when alive $ writeChan ourChan (ConnectionClosed connId) 
        return False

--------------------------------------------------------------------------------
-- Lower level functionality                                                  --
--------------------------------------------------------------------------------

-- | Create a new local endpoint
createLocalEndPoint :: TCPTransport -> IO LocalEndPoint
createLocalEndPoint transport = do 
  chan  <- newChan
  state <- newMVar LocalState { _nextConnectionId    = firstNonReservedConnectionId 
                              , _pendingCtrlRequests = IntMap.empty
                              , _nextCtrlRequestId   = 0
                              , _localConnections    = Map.empty
                              }
  let host = transportHost transport
  let port = transportPort transport 
  modifyMVar (transportState transport) $ \st -> do 
    let ix   = fromIntegral $ IntMap.size (st ^. localEndPoints) 
    let addr = EndPointAddress . BSC.pack $ host ++ ":" ++ port ++ ":" ++ show ix 
    let localEndPoint = LocalEndPoint { localAddress = addr
                                      , localChannel = chan
                                      , localState   = state
                                      }
    return ((localEndPointAt ix ^= Just localEndPoint) $ st, localEndPoint)

-- | Request a connection to a remote endpoint
--
-- This will block until we get a connection ID from the remote endpoint; if
-- the remote endpoint was in 'RemoteEndPointClosing' state then we will
-- additionally block until that is resolved. 
requestConnectionTo :: LocalEndPoint 
                    -> EndPointAddress 
                    -> ErrorT (FailedWith ConnectErrorCode) IO (RemoteEndPoint, ConnectionId)
requestConnectionTo ourEndPoint theirAddress = ErrorT go
  where
    go = do
      let ourState = localState ourEndPoint 
      theirEndPoint <- modifyMVar ourState $ \st ->
        case st ^. connectionTo theirAddress of
          Just theirEndPoint ->
            return (st, theirEndPoint)
          Nothing -> do
            theirState <- newEmptyMVar
            let theirEndPoint = RemoteEndPoint { remoteAddress = theirAddress
                                               , remoteState   = theirState
                                               }
            forkIO $ connectToRemoteEndPoint (ourEndPoint, theirEndPoint)
            return (connectionTo theirAddress ^= Just theirEndPoint $ st, theirEndPoint)

      -- Before we initiate the new connection request we want to make sure
      -- that refcount on the endpoint is incremented so that a concurrent
      -- thread will not close the connection. Note that if IF we return
      -- RemoteEndPointValid here then we can rely on the endpoint remaining in
      -- that state. 
      let theirState = remoteState theirEndPoint
      endPointStateSnapshot <- modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointValid ep ->
            return (RemoteEndPointValid . (remoteRefCount ^+= 1) $ ep, st)
          _ ->
            return (st, st)

      -- From this point on we are guaranteed the refcount is positive,
      -- provided that the endpoint was valid. We still need to deal with the
      -- case where it was not valid, however, which we didn't want to do that
      -- while holding the endpoint lock. 
      -- Although 'endPointStateSnapshot' here refers to a snapshot of the endpoint
      -- state, and might have changed in the meantime, these changes won't
      -- matter.
      case endPointStateSnapshot of
        RemoteEndPointInvalid err -> do
          return . Left $ err
    
        RemoteEndPointClosing _ resolved -> do
          -- If the remote endpoint is closing, then we need to block until
          -- this is resolved and we then try again
          readMVar resolved 
          go

        RemoteEndPointClosed -> do
          -- EndPointClosed indicates that a concurrent thread was in the
          -- process of closing the TCP connection to the remote endpoint when
          -- we obtained a reference to it. The remote endpoint will now have
          -- been removed from ourState, so we simply try again.
          go 
   
        RemoteEndPointValid _ -> do
          -- Do the actual connection request. This blocks until the remote
          -- endpoint replies (but note that we don't hold any locks at this
          -- point)
          mcid <- tryIO $ do
            reply <- doRemoteRequest (ourEndPoint, theirEndPoint) RequestConnectionId
            return (decodeInt32 . BS.concat $ reply) 
    
          -- On a failure we decrement the refcount again and return an error.
          -- The only state the remote endpoint can be in at this point is
          -- valid. As mentioned above, we can rely on the endpoint being in
          -- valid state at this point.
          let failed err = do
              modifyMVar_ theirState $ \(RemoteEndPointValid ep) -> 
                return (RemoteEndPointValid . (remoteRefCount ^+= (-1)) $ ep)
              return . Left $ FailedWith ConnectFailed err 
    
          case mcid of
            Left err         -> failed (show err) 
            Right Nothing    -> failed ("Invalid integer") 
            Right (Just cid) -> return . Right $ (theirEndPoint, cid)

-- | Establish a connection to a remote endpoint
-- 
-- RELY: The state of the remote endpoint must be uninitialized.
-- GUARANTEE: Will only change the state to RemoteEndPointValid or
--   RemoteEndPointInvalid. 
connectToRemoteEndPoint :: EndPointPair -> IO () 
connectToRemoteEndPoint (ourEndPoint, theirEndPoint) = do
    let ourState     = localState ourEndPoint
        theirState   = remoteState theirEndPoint
        theirAddress = remoteAddress theirEndPoint
    result <- runErrorT go 
    case result of
      Right (ConnectionRequestAccepted, sock) -> do 
        let remoteConn = RemoteConnection {  remoteSocket   = sock
                                          , _remoteRefCount = 0
                                          ,  sendOn         = sendMany sock 
                                          }
        putMVar theirState (RemoteEndPointValid remoteConn)
        void . forkIO $ handleIncomingMessages (ourEndPoint, theirEndPoint)
      Right (ConnectionRequestEndPointInvalid, sock) -> do
        -- We remove the endpoint from our local state again because the next
        -- call to 'connect' might give a different result. Threads that were
        -- waiting on the result of this call to connect will get the
        -- RemoteEndPointInvalid; subsequent threads will initiate a new
        -- connection requests. 
        modifyMVar_ ourState $ return . (connectionTo theirAddress ^= Nothing)
        putMVar theirState (RemoteEndPointInvalid (invalidAddress "Invalid endpoint"))
        N.sClose sock
      Right (ConnectionRequestCrossed, sock) -> do
        N.sClose sock
      Left err -> do 
        -- See comment above 
        modifyMVar_ ourState $ return . (connectionTo theirAddress ^= Nothing)
        putMVar theirState (RemoteEndPointInvalid err)
        -- TODO: this isn't quite right; socket *might* have been opened here, 
        -- in which case we should close it
  where
    go :: ErrorT (FailedWith ConnectErrorCode) IO (ConnectionRequestResponse, N.Socket)
    go = do
      let theirAddress = remoteAddress theirEndPoint
      (host, port, theirEndPointId) <- failWith (invalidAddress "Could not parse") $
        decodeEndPointAddress theirAddress
      addr:_ <- failWithIO (invalidAddress . show) $ 
        N.getAddrInfo Nothing (Just host) (Just port) 
      sock <- failWithIO (insufficientResources . show) $
        N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      response <- failWithIO (failed . show) $ do 
        N.setSocketOption sock N.ReuseAddr 1
        N.connect sock (N.addrAddress addr) 
        sendMany sock (encodeInt32 theirEndPointId : prependLength [ourAddress]) 
        recvInt32 sock
      case tryToEnum response of
        Nothing -> throwError (failed "Unexpected response")
        Just r  -> return (r, sock)

    invalidAddress, insufficientResources, failed :: String -> FailedWith ConnectErrorCode
    invalidAddress        = FailedWith ConnectInvalidAddress 
    insufficientResources = FailedWith ConnectInsufficientResources 
    failed                = FailedWith ConnectFailed
      
    ourAddress :: ByteString
    EndPointAddress ourAddress = localAddress ourEndPoint

-- | Decode end point address
-- TODO: This uses regular expression parsing, which is nice, but unnecessary
decodeEndPointAddress :: EndPointAddress -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) = match endPointAddressRE (BSC.unpack bs) 
  where
    endPointAddressRE :: RE Char (N.HostName, N.ServiceName, EndPointId)
    endPointAddressRE = (,,) <$> few anySym <*> (sym ':' *> few anySym) <*> (sym ':' *> (read <$> many anySym))

-- | Do a (blocking) remote request 
-- 
-- RELY: Remote endpoint must be in valid state.
-- GUARANTEE: Will not change the state of the remote endpoint.
doRemoteRequest :: EndPointPair -> ControlHeader -> IO ([ByteString])
doRemoteRequest (ourEndPoint, theirEndPoint) header = do
  reply <- newEmptyMVar
  reqId <- modifyMVar (localState ourEndPoint) $ \st -> do
    let reqId = st ^. nextCtrlRequestId
    return ((nextCtrlRequestId ^+= 1) . (pendingCtrlRequestsAt reqId ^= Just reply) $ st, reqId)
  withMVar (remoteState theirEndPoint) $ \(RemoteEndPointValid remoteConn) ->
    sendOn remoteConn [encodeInt32 header, encodeInt32 reqId]
  takeMVar reply 

-- | Decrease the remote refcount of a remote endpoint. When the refcount
-- reaches zero, initiate socket closure.
-- 
-- RELY: Remote endpoint must be in valid state.
-- GUARANTEE: Will leave the endpoint in its current state or change it to
--   RemoteEndPointClosing.
decreaseRemoteRefCount :: RemoteEndPoint -> IO ()
decreaseRemoteRefCount theirEndPoint = do
  modifyMVar_ (remoteState theirEndPoint) $ \(RemoteEndPointValid remoteConn) ->
    if remoteConn ^. remoteRefCount == 1
      then do
        resolved <- newEmptyMVar
        sendOn remoteConn [encodeInt32 CloseSocket]
        return (RemoteEndPointClosing remoteConn resolved)
      else do
        return (RemoteEndPointValid . (remoteRefCount ^+= (-1)) $ remoteConn)

--------------------------------------------------------------------------------
-- Incoming requests                                                          --
--------------------------------------------------------------------------------

-- | Handle a connection request (that is, a remote endpoint that is trying to
-- establish a TCP connection with us)
-- 
-- Returns the thread ID of the thread that is handling incoming messages.
handleConnectionRequest :: TCPTransport -> N.Socket -> IO (Maybe ThreadId) 
handleConnectionRequest transport sock = do
  request <- tryIO $ do 
    ourEndPointId <- recvInt32 sock
    theirAddress  <- EndPointAddress . BS.concat <$> recvWithLength sock 
    ourEndPoint   <- (^. localEndPointAt ourEndPointId) <$> readMVar (transportState transport) 
    return (theirAddress, ourEndPoint)
  case request of
    Right (_, Nothing) -> do
      sendMany sock [encodeInt32 ConnectionRequestEndPointInvalid]
      N.sClose sock
      return Nothing
    Right (theirAddress, Just ourEndPoint) -> do
      (crossed, theirEndPoint) <- modifyMVar (localState ourEndPoint) $ \st ->
        case st ^. connectionTo theirAddress of
          Nothing -> do
            theirState <- newEmptyMVar
            let theirEndPoint = RemoteEndPoint { remoteAddress = theirAddress
                                               , remoteState   = theirState
                                               }
            return (connectionTo theirAddress ^= Just theirEndPoint $ st, (False, theirEndPoint))
          Just theirEndPoint -> 
            return (st, (localAddress ourEndPoint < theirAddress, theirEndPoint))
      if crossed 
        then do
          sendMany sock [encodeInt32 ConnectionRequestCrossed]
          N.sClose sock
          return Nothing
        else do
          let remoteConn = RemoteConnection {  remoteSocket   = sock
                                            , _remoteRefCount = 0
                                            , sendOn          = sendMany sock
                                            }
          putMVar (remoteState theirEndPoint) (RemoteEndPointValid remoteConn)
          sendMany sock [encodeInt32 ConnectionRequestAccepted]
          tid <- forkIO $ handleIncomingMessages (ourEndPoint, theirEndPoint)
          return (Just tid)
    Left _ -> do
      -- Invalid request
      N.sClose sock
      return Nothing

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
    -- We use an IORef rather than the state monad because when an exception occurs we
    -- want to know the current list of open connections
    openConnections <- newIORef IntSet.empty

    -- For efficiency sake we get the socket once and for all
    sock <- withMVar theirState $ \st ->
      case st of
        RemoteEndPointValid ep ->
          return (remoteSocket ep)
        RemoteEndPointClosing ep _ ->
          return (remoteSocket ep)
        _ ->
          error "handleIncomingMessages RELY violation"
  
    tryIO $ go sock openConnections 
    unclosedConnections <- readIORef openConnections
    forM_ (map fromIntegral $ IntSet.elems unclosedConnections) $ 
      writeChan ourChannel . ConnectionClosed 
  where
    -- Dispatch 
    go :: N.Socket -> IORef IntSet -> IO ()
    go sock openConnections = do
      connId <- recvInt32 sock 
      if connId >= firstNonReservedConnectionId 
        then do
          readMessage sock connId
          go sock openConnections
        else do 
          case tryToEnum (fromIntegral connId) of
            Just RequestConnectionId -> do
              recvInt32 sock >>= createNewConnection openConnections
              go sock openConnections
            Just ControlResponse -> do 
              recvInt32 sock >>= readControlResponse sock 
              go sock openConnections
            Just CloseConnection -> do
              recvInt32 sock >>= closeConnection openConnections 
              go sock openConnections
            Just CloseSocket -> do 
              closeSocket sock 
              go sock openConnections
            Nothing ->
              -- Invalid control request, exit
              hPutStrLn stderr "Warning: invalid control request"
        
    -- Create a new connection
    createNewConnection :: IORef IntSet -> ControlRequestId -> IO () 
    createNewConnection openConnections reqId = do 
      modifyMVar_ theirState $ \st ->
        case st of
          RemoteEndPointValid ep ->
            return (RemoteEndPointValid . (remoteRefCount ^+= 1) $ ep)
          RemoteEndPointClosing ep resolved -> do
            -- If the endpoint is in closing state that means we send a
            -- CloseSocket request to the remote endpoint. If the remote
            -- endpoint replies with the request to create a new connection, it
            -- either ignored our request or it sent the request before it got
            -- ours.  Either way, at this point we simply restore the endpoint
            -- to RemoteEndPointValid
            putMVar resolved ()
            return (RemoteEndPointValid . (remoteRefCount ^= 1) $ ep) 
          _ ->
            error "handleIncomingMessages RELY violation"
      newId <- getNextConnectionId ourEndPoint
      withMVar theirState $ \(RemoteEndPointValid remoteConn) -> 
        sendOn remoteConn ( encodeInt32 ControlResponse 
                          : encodeInt32 reqId 
                          : prependLength [encodeInt32 newId] 
                          )
      writeChan ourChannel (ConnectionOpened newId ReliableOrdered theirAddr) 
      -- We add the new connection ID to the list of open connections only once the
      -- endpoint has been notified of the new connection (sendOn may fail)
      modifyIORef openConnections (IntSet.insert (fromIntegral newId))

    -- Read a control response 
    readControlResponse :: N.Socket -> ControlRequestId -> IO () 
    readControlResponse sock reqId = do
      response <- recvWithLength sock
      mmvar    <- modifyMVar ourState $ \st ->
        return (pendingCtrlRequestsAt reqId ^= Nothing $ st, st ^. pendingCtrlRequestsAt reqId)
      case mmvar of
        Nothing -> do 
          hPutStrLn stderr $ "Warning: Invalid request ID"
          return () -- Invalid request ID. TODO: We just ignore it?
        Just mvar -> 
          putMVar mvar response

    -- Close a connection 
    closeConnection :: IORef IntSet -> ConnectionId -> IO () 
    closeConnection openConnections cid = do
      writeChan ourChannel (ConnectionClosed cid)
      decreaseRemoteRefCount theirEndPoint
      modifyIORef openConnections (IntSet.delete (fromIntegral cid))

    -- Close the socket (if we don't have any outgoing connections)
    closeSocket :: N.Socket -> IO Bool 
    closeSocket sock = do
      didClose <- modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointValid remoteConn | remoteConn ^. remoteRefCount == 0 -> do
            sendOn remoteConn [encodeInt32 CloseSocket]
            N.sClose sock
            return (RemoteEndPointClosed, True)
          RemoteEndPointClosing _ resolved -> do
            -- If the socket is already in closing state, then we have already
            -- sent a CloseSocket request; hence, we don't need to do it again
            -- at this point
            putMVar resolved ()
            N.sClose sock
            return (RemoteEndPointClosed, True)
          _ ->
            return (st, False)
      when didClose $ modifyMVar_ ourState $ return . (connectionTo theirAddr ^= Nothing) 
      return didClose

    -- Read a message and output it on the endPoint's channel
    readMessage :: N.Socket -> ConnectionId -> IO () 
    readMessage sock connId = recvWithLength sock >>= writeChan ourChannel . Received connId

    -- Arguments
    ourChannel = localChannel ourEndPoint 
    ourState   = localState ourEndPoint 
    theirState = remoteState theirEndPoint
    theirAddr  = remoteAddress theirEndPoint

-- | Get the next connection ID
getNextConnectionId :: LocalEndPoint -> IO ConnectionId
getNextConnectionId ourEndpoint = 
  modifyMVar (localState ourEndpoint) $ \st -> do 
    let connId = st ^. nextConnectionId 
    return (nextConnectionId ^= connId +1 $ st, connId)
    
--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

-- | We reserve a bunch of connection IDs for control messages
firstNonReservedConnectionId :: ConnectionId
firstNonReservedConnectionId = 1024

--------------------------------------------------------------------------------
-- Lens definitions                                                           --
--------------------------------------------------------------------------------

localEndPoints :: Lens TransportState (IntMap LocalEndPoint)
localEndPoints = lens _localEndPoints (\es st -> st { _localEndPoints = es })

pendingCtrlRequests :: Lens LocalState (IntMap (MVar [ByteString]))
pendingCtrlRequests = lens _pendingCtrlRequests (\rep st -> st { _pendingCtrlRequests = rep })

nextCtrlRequestId :: Lens LocalState ControlRequestId 
nextCtrlRequestId = lens _nextCtrlRequestId (\cid st -> st { _nextCtrlRequestId = cid })

nextConnectionId :: Lens LocalState ConnectionId
nextConnectionId = lens _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

localConnections :: Lens LocalState (Map EndPointAddress RemoteEndPoint)
localConnections = lens _localConnections (\es st -> st { _localConnections = es })

localEndPointAt :: EndPointId -> Lens TransportState (Maybe LocalEndPoint)
localEndPointAt ix = localEndPoints >>> intMapLens (fromIntegral ix)

pendingCtrlRequestsAt :: ControlRequestId -> Lens LocalState (Maybe (MVar [ByteString]))
pendingCtrlRequestsAt ix = pendingCtrlRequests >>> intMapLens (fromIntegral ix)

connectionTo :: EndPointAddress -> Lens LocalState (Maybe RemoteEndPoint)
connectionTo addr = localConnections >>> mapLens addr 

remoteRefCount :: Lens RemoteConnection Int
remoteRefCount = lens _remoteRefCount (\rc conn -> conn { _remoteRefCount = rc })
