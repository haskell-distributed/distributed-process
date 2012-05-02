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
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar ( MVar
                               , newMVar
                               , modifyMVar
                               , modifyMVar_
                               , readMVar
                               , takeMVar
                               , putMVar
                               , newEmptyMVar
                               )
import Control.Category ((>>>))
import Control.Applicative ((<*>), (*>), (<$>))
import Control.Monad (forM_, void, unless, when)
import Control.Monad.Error (ErrorT(ErrorT), runErrorT)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (IOException, bracket_)
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
import Data.IORef (newIORef, modifyIORef, readIORef) 
import Data.Lens.Lazy (Lens, lens, intMapLens, mapLens, (^.), (^=), (^+=))
import Text.Regex.Applicative (RE, few, anySym, sym, many, match)

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
-- Ignoring the complications detailed below, the TCP connection is created is
-- created the first lightweight connection is created (in either direction),
-- and torn down when the last lightweight connection (in either direction) is
-- closed.
--
-- [Connecting]
--
-- Let /A/, /B/ be two endpoints without any connections. When /A/ wants to
-- connect to /B/, it locally records that it is trying to connect to /B/ and
-- sends a request to /B/. As part of the request /A/ sends its own endpoint
-- address to /B/ (so that /B/ can reuse the connection in the other direction).
--
-- When /B/ receives the connection request it first checks if it had not
-- already initiated a connection request to /A/. If it had not, then it will
-- acknowledge the connection request by sending 'ConnectionRequestAccepted' to
-- /A/ and record that it has a TCP connection to /A/.
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

data TCPTransport   = TCPTransport   { _transportHost       :: N.HostName
                                     , _transportPort       :: N.ServiceName
                                     , _transportState      :: MVar TransportState 
                                     }
data TransportState = TransportState { _localEndPoints      :: IntMap LocalEndPoint }
data LocalEndPoint  = LocalEndPoint  { _localAddress        :: EndPointAddress
                                     , _localChannel        :: Chan Event
                                     , _localState          :: MVar LocalState 
                                     }
data LocalState     = LocalState     { _nextConnectionId    :: ConnectionId 
                                     , _pendingCtrlRequests :: IntMap (MVar [ByteString])
                                     , _nextCtrlRequestId   :: ControlRequestId 
                                     , _localConnections    :: Map EndPointAddress (IsClosing, MVar RemoteState)
                                     }
data RemoteEndPoint = RemoteEndPoint { _remoteAddress       :: EndPointAddress
                                     , _remoteSocket        :: N.Socket
                                     , sendTo               :: [ByteString] -> IO ()
                                     }
data RemoteState    = EndPointInvalid (FailedWith ConnectErrorCode)
                    | EndPointValid !RefCount RemoteEndPoint
                    | EndPointClosed

type EndPointId       = Int32
type ControlRequestId = Int32
type RefCount         = Int32
type IsClosing        = Maybe RemoteEndPoint 
type Conn             = (LocalEndPoint, RemoteEndPoint)

-- | Control headers 
data ControlHeader = 
    RequestConnectionId -- ^ Request a new connection ID from the remote endpoint
  | CloseConnection     -- ^ Tell the remote endpoint we will no longer be using a connection
  | ControlResponse     -- ^ Respond to a control request _from_ the remote endpoint
  | CloseSocket         -- ^ Request to close the connection (see module description)
  deriving Enum

-- Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    ConnectionRequestAccepted        -- ^ /B/ accepts the connection
  | ConnectionRequestEndPointInvalid -- ^ /A/ requested an invalid endpoint
  | ConnectionRequestCrossed         -- ^ /A/s request crossed with a request from /B/ (see protocols)
  deriving Enum

--------------------------------------------------------------------------------
-- Top-level functionality                                                    --
--------------------------------------------------------------------------------

-- | Create a TCP transport
--
-- TODOs: deal with hints
createTransport :: N.HostName -> N.ServiceName -> IO (Either IOException Transport)
createTransport host port = do 
  state <- newMVar TransportState { _localEndPoints = IntMap.empty }
  let transport = TCPTransport    { _transportState = state
                                  , _transportHost  = host
                                  , _transportPort  = port
                                  }
  tryIO $ do 
    forkServer host port $ handleConnectionRequest transport
    return Transport { newEndPoint = apiNewEndPoint transport } 

--------------------------------------------------------------------------------
-- API functions                                                              --
--------------------------------------------------------------------------------

-- | Create a new endpoint 
apiNewEndPoint :: TCPTransport -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
apiNewEndPoint transport = do 
  ourEndPoint <- createLocalEndPoint transport
  return . Right $ EndPoint { receive = readChan (ourEndPoint ^. localChannel) 
                            , address = ourEndPoint ^. localAddress 
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
apiConnect ourEndPoint theirAddress _ = runErrorT $ do
  theirEndPoint <- findRemoteEndPoint ourEndPoint theirAddress 
  connId        <- requestNewConnection (ourEndPoint, theirEndPoint)
  connAlive     <- liftIO $ newMVar True 
  return $ Connection { send  = apiSend theirEndPoint connId connAlive
                      , close = apiClose (ourEndPoint, theirEndPoint) connId connAlive
                      }

-- | Close a connection
--
-- TODO: We ignore errors during a close. Is that right? 
apiClose :: Conn -> ConnectionId -> MVar Bool -> IO ()
apiClose (ourEndPoint, theirEndPoint) connId connAlive = void . tryIO $ do 
  modifyMVar_ connAlive $ \alive -> do
    when alive $ do 
      sendTo theirEndPoint [encodeInt32 CloseConnection, encodeInt32 connId] 
      decreaseRemoteRefCount (ourEndPoint, theirEndPoint)
    return False

-- | Send data across a connection
apiSend :: RemoteEndPoint -> ConnectionId -> MVar Bool -> [ByteString] -> IO (Either (FailedWith SendErrorCode) ())
apiSend theirEndPoint connId connAlive payload = 
  modifyMVar connAlive $ \alive -> do
    if alive
      then do 
        result <- tryIO $ sendTo theirEndPoint (encodeInt32 connId : prependLength payload)
        case result of
          Left err -> return (alive, Left $ FailedWith SendFailed (show err))
          Right _  -> return (alive, Right $ ())
      else do
        return (alive, Left $ FailedWith SendConnectionClosed "Connection closed")

--------------------------------------------------------------------------------
-- Lower level functionality                                                  --
--------------------------------------------------------------------------------

createLocalEndPoint :: TCPTransport -> IO LocalEndPoint
createLocalEndPoint transport = do 
  chan  <- newChan
  state <- newMVar LocalState { _nextConnectionId    = firstNonReservedConnectionId 
                              , _pendingCtrlRequests = IntMap.empty
                              , _nextCtrlRequestId   = 0
                              , _localConnections    = Map.empty
                              }
  let host = transport ^. transportHost
  let port = transport ^. transportPort
  modifyMVar (transport ^. transportState) $ \st -> do 
    let ix   = fromIntegral $ IntMap.size (st ^. localEndPoints) 
    let addr = EndPointAddress . BSC.pack $ host ++ ":" ++ port ++ ":" ++ show ix 
    let localEndPoint = LocalEndPoint { _localAddress = addr
                                      , _localChannel = chan
                                      , _localState   = state
                                      }
    return ((localEndPointAt ix ^= Just localEndPoint) $ st, localEndPoint)

findRemoteEndPoint :: LocalEndPoint 
                   -> EndPointAddress 
                   -> ErrorT (FailedWith ConnectErrorCode) IO RemoteEndPoint
findRemoteEndPoint ourEndPoint theirAddress = ErrorT $ go
  where
    go = do
      endPoint <- modifyMVar state $ \st -> 
        case st ^. connectionTo theirAddress of 
          Just (_, mvar) -> 
            return (st, mvar)
          Nothing -> do 
            theirMVar <- newEmptyMVar
            forkIO $ connectToRemoteEndPoint ourEndPoint theirMVar theirAddress
            return (connectionTo theirAddress ^= Just (Nothing, theirMVar) $ st, theirMVar)
      theirState <- readMVar endPoint
      case theirState of
        EndPointInvalid err ->
          -- We remove the endpoint from the state again because the next call
          -- to 'connect' might give a different result
          modifyMVar state $ \st ->
            return (connectionTo theirAddress ^= Nothing $ st, Left err)
        EndPointValid _ ep ->
          return $ Right ep
        EndPointClosed ->
          go 

    state :: MVar LocalState 
    state = ourEndPoint ^. localState 
  
connectToRemoteEndPoint :: LocalEndPoint -> MVar RemoteState -> EndPointAddress -> IO ()
connectToRemoteEndPoint ourEndPoint theirMVar theirAddress = do
    result <- runErrorT go 
    case result of
      Right (ConnectionRequestAccepted, sock) -> do 
        theirEndPoint <- createRemoteEndPoint ourEndPoint theirAddress sock
        putMVar theirMVar (EndPointValid 0 theirEndPoint)
      Right (ConnectionRequestEndPointInvalid, sock) -> do
        putMVar theirMVar (EndPointInvalid (invalidAddress "Invalid endpoint"))
        N.sClose sock
      Right (ConnectionRequestCrossed, sock) ->
        N.sClose sock
      Left err -> 
        -- TODO: this isn't quite right; socket *might* have been opened here, 
        -- in which case we should close it
        putMVar theirMVar (EndPointInvalid err)
  where
    go :: ErrorT (FailedWith ConnectErrorCode) IO (ConnectionRequestResponse, N.Socket)
    go = do
      (host, port, theirEndPointId) <- failWith (invalidAddress "Could not parse") $
        decodeEndPointAddress theirAddress
      addr:_ <- failWithIO (invalidAddress . show) $ 
        N.getAddrInfo Nothing (Just host) (Just port) 
      sock <- failWithIO (insufficientResources . show) $
        N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      failWithIO (failed . show) $ do 
        N.setSocketOption sock N.ReuseAddr 1
        N.connect sock (N.addrAddress addr) 
        sendMany sock (encodeInt32 theirEndPointId : prependLength [ourAddress]) 
        -- TODO: what happens when the server sends an int outside the range of ConnectionRequestResponse?
        response <- recvInt32 sock
        return (response, sock)

    invalidAddress, insufficientResources, failed :: String -> FailedWith ConnectErrorCode
    invalidAddress        = FailedWith ConnectInvalidAddress 
    insufficientResources = FailedWith ConnectInsufficientResources 
    failed                = FailedWith ConnectFailed
      
    ourAddress :: ByteString
    EndPointAddress ourAddress = ourEndPoint ^. localAddress

-- | Request a new connection 
requestNewConnection :: Conn -> ErrorT (FailedWith ConnectErrorCode) IO ConnectionId
requestNewConnection (ourEndPoint, theirEndPoint) = ErrorT $ do 
    -- We increment the refcount before sending the request, because if a
    -- CloseSocket request comes this way first we want to ignore it
    increaseRemoteRefCount (ourEndPoint, theirEndPoint)
    mcid <- tryIO $ do 
      reply <- sendRemoteRequest (ourEndPoint, theirEndPoint) RequestConnectionId 
      decodeInt32 . BS.concat <$> takeMVar reply
    case mcid of
      Left err         -> do decreaseRemoteRefCount (ourEndPoint, theirEndPoint) 
                             return . Left  $ failed (show err)
      Right Nothing    -> do decreaseRemoteRefCount (ourEndPoint, theirEndPoint) 
                             return . Left  $ failed "Invalid integer"
      Right (Just cid) -> do return . Right $ cid
  where
    failed = FailedWith ConnectFailed

-- | Decode end point address
-- TODO: This uses regular expression parsing, which is nice, but unnecessary
decodeEndPointAddress :: EndPointAddress -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) = match endPointAddressRE (BSC.unpack bs) 
  where
    endPointAddressRE :: RE Char (N.HostName, N.ServiceName, EndPointId)
    endPointAddressRE = (,,) <$> few anySym <*> (sym ':' *> few anySym) <*> (sym ':' *> (read <$> many anySym))

sendRemoteRequest :: Conn -> ControlHeader -> IO (MVar [ByteString])
sendRemoteRequest (ourEndPoint, theirEndPoint) header = do
  reply <- newEmptyMVar
  reqId <- modifyMVar (ourEndPoint ^. localState) $ \st -> do
    let reqId = st ^. nextCtrlRequestId
    return ((nextCtrlRequestId ^+= 1) . (pendingCtrlRequestsAt reqId ^= Just reply) $ st, reqId)
  sendTo theirEndPoint [encodeInt32 header, encodeInt32 reqId]
  return reply 

--------------------------------------------------------------------------------
-- Reference counting                                                         -- 
--------------------------------------------------------------------------------

increaseRemoteRefCount :: Conn -> IO ()
increaseRemoteRefCount (ourEndPoint, theirEndPoint) = do
  let theirAddr = theirEndPoint ^. remoteAddress
      state     = ourEndPoint ^. localState
  -- If this endpoint was closing, cancel that 
  theirMVar <- modifyMVar state $ \st -> do
    let Just (isClosing, theirMVar) = st ^. connectionTo theirAddr
    case isClosing of
      Nothing -> 
        return (st, theirMVar)
      Just ep -> do
        putMVar theirMVar (EndPointValid 0 ep)
        return (connectionTo theirAddr ^= Just (Nothing, theirMVar) $ st, theirMVar)
  -- Increase the refcount
  modifyMVar_ theirMVar $ \(EndPointValid rc ep) ->
    return (EndPointValid (rc + 1) ep)
  
decreaseRemoteRefCount :: Conn -> IO ()
decreaseRemoteRefCount (ourEndPoint, theirEndPoint) = do
  let theirAddr = theirEndPoint ^. remoteAddress
  state <- readMVar (ourEndPoint ^. localState)
  let Just (Nothing, theirMVar) = state ^. connectionTo theirAddr 
  -- We don't use modifyMVar here because we want to leave the MVar
  -- empty when refcount reaches 0
  -- TODO: deal with exceptions
  EndPointValid rc ep <- takeMVar theirMVar
  if rc > 1
    then do 
      putMVar theirMVar (EndPointValid (rc - 1) ep)
    else do
      sendTo theirEndPoint [encodeInt32 CloseSocket]
      modifyMVar_ (ourEndPoint ^. localState) $ \st -> do
        let Just (_, mvar) = st ^. connectionTo theirAddr
        return (connectionTo theirAddr ^= Just (Just ep, mvar) $ st) 

--------------------------------------------------------------------------------
-- Incoming requests                                                          --
--------------------------------------------------------------------------------

handleConnectionRequest :: TCPTransport -> N.Socket -> IO ()
handleConnectionRequest transport sock = do
  request <- tryIO $ do 
    ourEndPointId <- recvInt32 sock
    theirAddress  <- EndPointAddress . BS.concat <$> recvWithLength sock 
    ourEndPoint   <- (^. localEndPointAt ourEndPointId) <$> readMVar state 
    return (theirAddress, ourEndPoint)
  case request of
    Right (_, Nothing) -> do
      sendMany sock [encodeInt32 ConnectionRequestEndPointInvalid]
      N.sClose sock
    Right (theirAddress, Just ourEndPoint) -> do
      (crossed, mvar) <- modifyMVar (ourEndPoint ^. localState) $ \st ->
        case st ^. connectionTo theirAddress of
          Nothing -> do
            mvar <- newEmptyMVar
            return (connectionTo theirAddress ^= Just (Nothing, mvar) $ st, (False, mvar))
          Just (_, mvar) -> 
            return (st, (ourEndPoint ^. localAddress <= theirAddress, mvar))
      if crossed 
        then do
          sendMany sock [encodeInt32 ConnectionRequestCrossed]
          N.sClose sock
        else do
          theirEndPoint <- createRemoteEndPoint ourEndPoint theirAddress sock 
          putMVar mvar (EndPointValid 0 theirEndPoint)
          sendMany sock [encodeInt32 ConnectionRequestAccepted]
    Left _ ->
      -- Invalid request
      N.sClose sock

  where
    state :: MVar TransportState
    state = transport ^. transportState

createRemoteEndPoint :: LocalEndPoint -> EndPointAddress -> N.Socket -> IO RemoteEndPoint 
createRemoteEndPoint ourEndPoint theirAddress sock = do
  lock <- newMVar ()
  let theirEndPoint = RemoteEndPoint { _remoteAddress = theirAddress
                                     , _remoteSocket  = sock
                                     , sendTo         = bracket_ (takeMVar lock) (putMVar lock ())
                                                      . sendMany sock
                                     }
  forkIO $ do
    unclosedConnections <- handleIncomingMessages (ourEndPoint, theirEndPoint)
    forM_ (map fromIntegral $ IntSet.elems unclosedConnections) $ 
      writeChan (ourEndPoint ^. localChannel) . ConnectionClosed 
  return theirEndPoint

-- | Handle requests from a remote endpoint.
-- 
-- Returns only if the remote party closes the socket or if an error occurs.
-- The return value is the list of  connections that are still open (normally,
-- this should be an empty list).
handleIncomingMessages :: Conn -> IO IntSet 
handleIncomingMessages (ourEndPoint, theirEndPoint) = do
  -- We use an IORef rather than the state monad because when an exception occurs we
  -- want to know the current list of open connections
  openConnections <- newIORef IntSet.empty

  let go :: IO ()
      go = do 
        connId <- recvInt32 sock
        if connId >= firstNonReservedConnectionId 
          then readMessage connId 
          else do 
            case toEnum (fromIntegral connId) of
              RequestConnectionId -> recvInt32 sock >>= createNewConnection 
              ControlResponse     -> recvInt32 sock >>= readControlResponse
              CloseConnection     -> recvInt32 sock >>= closeConnection 
              CloseSocket         -> closeSocket 

      -- Create a new connection
      createNewConnection :: ControlRequestId -> IO () 
      createNewConnection reqId = do 
        increaseRemoteRefCount (ourEndPoint, theirEndPoint)
        newId <- getNextConnectionId ourEndPoint 
        sendTo theirEndPoint ( encodeInt32 ControlResponse 
                             : encodeInt32 reqId 
                             : prependLength [encodeInt32 newId] 
                             )
        writeChan ourChannel (ConnectionOpened newId ReliableOrdered theirAddr) 
        -- We add the new connection ID to the list of open connections only once the
        -- endpoint has been notified of the new connection (sendMany may fail)
        modifyIORef openConnections (IntSet.insert (fromIntegral newId))
        go

      -- Read a control response 
      readControlResponse :: ControlRequestId -> IO () 
      readControlResponse reqId = do
        response <- recvWithLength sock
        mmvar    <- (^. pendingCtrlRequestsAt reqId) <$> readMVar ourState  
        case mmvar of
          Nothing   -> 
            return () -- Invalid request ID. TODO: We just ignore it?
          Just mvar -> do 
            modifyMVar_ ourState $ return . (pendingCtrlRequestsAt reqId ^= Nothing)
            putMVar mvar response
        go

      -- Close a connection 
      closeConnection :: ConnectionId -> IO () 
      closeConnection cid = do
        writeChan ourChannel (ConnectionClosed cid)
        decreaseRemoteRefCount (ourEndPoint, theirEndPoint)
        modifyIORef openConnections (IntSet.delete (fromIntegral cid))
        go

      -- Close the socket (if we don't have any outgoing connections)
      closeSocket :: IO ()
      closeSocket = do
        didClose <- modifyMVar (ourEndPoint ^. localState) $ \st -> do
          case st ^. connectionTo theirAddr of
            Just (Just _, mvar) -> do
              -- The connection is already in "closing" state, which means we
              -- don't need to send another CloseSocket request (we already did)
              N.sClose sock
              putMVar mvar EndPointClosed  
              return (connectionTo theirAddr ^= Nothing $ st, True)
            Just (Nothing, theirMVar) -> do
              EndPointValid rc _ <- readMVar theirMVar
              if rc == 0
                then do 
                  sendTo theirEndPoint [encodeInt32 CloseSocket] 
                  N.sClose sock
                  return (connectionTo theirAddr ^= Nothing $ st, True)
                else do 
                  return (st, False)
            Nothing -> do
              error "Internal error"
        unless didClose go

      -- Read a message and output it on the endPoint's channel
      readMessage :: ConnectionId -> IO () 
      readMessage connId = recvWithLength sock >>= writeChan ourChannel . Received connId >> go

      -- Breakdown of the arguments
      ourChannel =   ourEndPoint ^. localChannel
      ourState   =   ourEndPoint ^. localState 
      sock       = theirEndPoint ^. remoteSocket
      theirAddr  = theirEndPoint ^. remoteAddress

  -- We keep handling messages until an exception occurs
  tryIO go 
  readIORef openConnections

-- | Get the next connection ID
getNextConnectionId :: LocalEndPoint -> IO ConnectionId
getNextConnectionId endpoint = 
  modifyMVar (endpoint ^. localState) $ \st -> 
    return (nextConnectionId ^+= 1 $ st, st ^. nextConnectionId)
    
--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

-- | We reserve a bunch of connection IDs for control messages
firstNonReservedConnectionId :: ConnectionId
firstNonReservedConnectionId = 1024

--------------------------------------------------------------------------------
-- Lens definitions                                                           --
--------------------------------------------------------------------------------

transportState :: Lens TCPTransport (MVar TransportState)
transportState = lens _transportState (\st trans -> trans { _transportState = st })

transportHost :: Lens TCPTransport N.HostName
transportHost = lens _transportHost (\host trans -> trans { _transportHost = host })

transportPort :: Lens TCPTransport N.ServiceName
transportPort = lens _transportPort (\port trans -> trans { _transportPort = port })

localEndPoints :: Lens TransportState (IntMap LocalEndPoint)
localEndPoints = lens _localEndPoints (\es st -> st { _localEndPoints = es })

localAddress :: Lens LocalEndPoint EndPointAddress
localAddress = lens _localAddress (\addr ep -> ep { _localAddress = addr })

localChannel :: Lens LocalEndPoint (Chan Event)
localChannel = lens _localChannel (\ch ep -> ep { _localChannel = ch })

localState :: Lens LocalEndPoint (MVar LocalState)
localState = lens _localState (\st ep -> ep { _localState = st })

pendingCtrlRequests :: Lens LocalState (IntMap (MVar [ByteString]))
pendingCtrlRequests = lens _pendingCtrlRequests (\rep st -> st { _pendingCtrlRequests = rep })

nextCtrlRequestId :: Lens LocalState ControlRequestId 
nextCtrlRequestId = lens _nextCtrlRequestId (\cid st -> st { _nextCtrlRequestId = cid })

nextConnectionId :: Lens LocalState ConnectionId
nextConnectionId = lens _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

localConnections :: Lens LocalState (Map EndPointAddress (IsClosing, MVar RemoteState))
localConnections = lens _localConnections (\cs st -> st { _localConnections = cs })

remoteAddress :: Lens RemoteEndPoint EndPointAddress
remoteAddress = lens _remoteAddress (\addr ep -> ep { _remoteAddress = addr })

remoteSocket :: Lens RemoteEndPoint N.Socket
remoteSocket = lens _remoteSocket (\sock ep -> ep { _remoteSocket = sock })

localEndPointAt :: EndPointId -> Lens TransportState (Maybe LocalEndPoint)
localEndPointAt ix = localEndPoints >>> intMapLens (fromIntegral ix)

pendingCtrlRequestsAt :: ControlRequestId -> Lens LocalState (Maybe (MVar [ByteString]))
pendingCtrlRequestsAt ix = pendingCtrlRequests >>> intMapLens (fromIntegral ix)

connectionTo :: EndPointAddress -> Lens LocalState (Maybe (IsClosing, MVar RemoteState))
connectionTo addr = localConnections >>> mapLens addr 
