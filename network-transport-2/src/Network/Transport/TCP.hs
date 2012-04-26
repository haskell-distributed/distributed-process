-- | TCP transport
--
-- TODOs:
-- * Various errors are still left as "undefined"
-- * Many possible errors are not yet dealt with

module Network.Transport.TCP ( -- * Main API
                               createTransport
                             , -- TCP specific functionality
                               EndPointId
                             , decodeEndPointAddress
                             ) where

import Network.Transport
import Network.Transport.Internal.TCP ( forkServer
                                      , recvWithLength
                                      , sendMany
                                      , recvInt32
                                      )
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
                                  , prependLength
                                  , failWith
                                  , failWithIO
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , sClose
                                     , accept
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
import Control.Monad (forever, forM_, void)
import Control.Monad.Error (MonadError, ErrorT, liftIO, runErrorT, throwError)
import Control.Monad.Trans.Maybe (MaybeT(MaybeT), runMaybeT)
import Control.Monad.Trans.Writer (WriterT, execWriterT)
import Control.Monad.Writer.Class (tell)
import Control.Monad.IO.Class (MonadIO)
import Control.Exception (IOException)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Data.Int (Int32)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty, size)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Lens.Lazy (Lens, lens, intMapLens, mapLens, (^.), (^=), (^+=))
import Text.Regex.Applicative (RE, few, anySym, sym, many, match)

data TCPTransport   = TCPTransport   { _transportHost       :: N.HostName
                                     , _transportPort       :: N.ServiceName
                                     , _transportState      :: MVar TransportState
                                     }
data TransportState = TransportState { _localEndPoints      :: IntMap LocalEndPoint 
                                     , _remoteEndPoints     :: Map EndPointAddress RemoteEndPoint 
                                     }
data LocalEndPoint  = LocalEndPoint  { _localAddress        :: EndPointAddress
                                     , _localChannel        :: Chan Event
                                     , _localState          :: MVar EndPointState 
                                     }
data RemoteEndPoint = RemoteEndPoint { _remoteAddress       :: EndPointAddress
                                     , _remoteSocket        :: N.Socket
                                     , _remoteLock          :: MVar ()
                                     }
data EndPointState  = EndPointState  { _nextConnectionId    :: ConnectionId 
                                     , _pendingCtrlRequests :: IntMap (MVar [ByteString])
                                     , _nextCtrlRequestId   :: ControlRequestId 
                                     }
type EndPointId       = Int32
type ControlRequestId = Int32

-- | Create a TCP transport
--
-- Hostname and service name should be "canonical" for the transport layer to
-- use TCP channels bidirectionally (otherwise when A connects to B and B
-- connects to A two socket pairs will be created that will both be used
-- unidirectionally, at degraded performance). 
--
-- TODOs: deal with hints
createTransport :: N.HostName -> N.ServiceName -> IO (Either IOException Transport)
createTransport host port = do 
  state <- newMVar TransportState { _localEndPoints  = IntMap.empty 
                                  , _remoteEndPoints = Map.empty
                                  }
  let transport = TCPTransport { _transportState = state
                               , _transportHost  = host
                               , _transportPort  = port
                               }
  runErrorT $ do 
    forkServer host port (transportServer transport)
    return Transport { newEndPoint = tcpNewEndPoint transport } 

-- | The transport server handles incoming connections for all endpoints
--
-- TODO: lots of error checking
transportServer :: TCPTransport -> N.Socket -> IO ()
transportServer transport sock = forever $ do
  (clientSock, _) <- N.accept sock
  handleConnectionRequest transport clientSock

-- | Set up a new TCP connection (at the request of a remote endpoint)
handleConnectionRequest :: TCPTransport -> N.Socket -> IO ()
handleConnectionRequest transport sock = do
  request <- runMaybeT $ do 
    ourEndPointId <- recvInt32 sock
    theirAddress  <- EndPointAddress . BS.concat <$> recvWithLength sock 
    ourEndPoint   <- MaybeT $ (^. localEndPointAt ourEndPointId) <$> readMVar (transport ^. transportState) 
    return (ourEndPoint, theirAddress)
  case request of
    Just (ourEndPoint, theirAddress) -> 
      -- We ignore the return value of 'forkRemoteEndPoint' here because _they_ are 
      -- connecting to _us_. 'forkRemoteEndPoint' will have stored the remote endpoint
      -- in the transport state, however, in case _we_ later connect to _them_.
      void $ forkRemoteEndPoint transport ourEndPoint theirAddress sock
    Nothing -> 
      return ()  

-- | Set up a new remote endpoint (either because we connected to a 
-- new remote endpoint, or because a remote endpoint connected to us)
forkRemoteEndPoint :: TCPTransport          
                   -> LocalEndPoint
                   -> EndPointAddress
                   -> N.Socket
                   -> IO RemoteEndPoint 
forkRemoteEndPoint transport ourEndPoint theirAddress sock = do
  lock <- newMVar ()
  let theirEndPoint = RemoteEndPoint { _remoteAddress = theirAddress
                                     , _remoteSocket  = sock 
                                     , _remoteLock    = lock 
                                     }
  modifyMVar_ (transport ^. transportState) $ return . (remoteEndPointAt theirAddress ^= Just theirEndPoint)
  forkIO $ do
    unclosedConnections <- handleIncomingMessages ourEndPoint theirEndPoint  
    forM_ unclosedConnections $ \cix -> writeChan (ourEndPoint ^. localChannel) (ConnectionClosed cix)
    -- TODO: should we close the socket here? (forkRemoteEndPoint gets called from multiple places)
    -- TODO: and should we remove it from the transaction state?
  return theirEndPoint

-- Control headers 
data ControlHeaders = 
    RequestConnectionId -- ^ Request a new connection ID from the remote endpoint
  | ControlResponse     -- ^ Respond to a control request _from_ the remote endpoint
  deriving Enum

-- | Handle requests from a remote endpoint.
-- 
-- Returns only if the remote party closes the socket or if an error occurs.
-- The return value is the list of  connections that are still open (normally,
-- this should be an empty list).
handleIncomingMessages :: LocalEndPoint -> RemoteEndPoint -> IO [ConnectionId] 
handleIncomingMessages ourEndPoint theirEndPoint = execWriterT . runMaybeT . forever $ do
    connId <- recvInt32 sock
    if connId >= firstNonReservedConnectionId 
      then readMessage connId 
      else do 
        reqId <- recvInt32 sock
        case toEnum (fromIntegral connId) of
          RequestConnectionId -> createNewConnection reqId
          ControlResponse     -> readControlResponse reqId
  where
    -- A brief note on the types:
    -- These functions may fail (connection error): hence MaybeT
    -- We also need to keep track of which connections are still open: hence WriterT

    -- Create a new connection
    createNewConnection :: ControlRequestId -> MaybeT (WriterT [ConnectionId] IO) () 
    createNewConnection reqId = do
      newId <- liftIO $ getNextConnectionId ourEndPoint 
      withRemoteLock theirEndPoint $ do 
        sendMany sock (encodeInt32 ControlResponse : encodeInt32 reqId : prependLength [encodeInt32 newId])
      liftIO $ writeChan ourChannel (ConnectionOpened newId ReliableOrdered (theirEndPoint ^. remoteAddress)) 
      -- We add the new connection ID to the list of open connections only once the
      -- endpoint has been notified of the new connection (sendInt32 may fail)
      tell [newId]
    
    -- Read a control response 
    readControlResponse :: ControlRequestId -> MaybeT (WriterT [ConnectionId] IO) ()
    readControlResponse reqId = do
      response <- recvWithLength sock
      mmvar    <- liftIO $ (^. pendingCtrlRequestsAt reqId) <$> readMVar ourState  
      case mmvar of
        Nothing   -> return () -- Invalid request ID. TODO: We just ignore it?
        Just mvar -> liftIO $ putMVar mvar response

    -- Read a message and output it on the endPoint's channel
    readMessage :: ConnectionId -> MaybeT (WriterT [ConnectionId] IO) ()
    readMessage connId = recvWithLength sock >>= liftIO . writeChan ourChannel . Received connId

    -- Breakdown of the arguments
    ourChannel =   ourEndPoint ^. localChannel
    ourState   =   ourEndPoint ^. localState 
    sock       = theirEndPoint ^. remoteSocket

-- | Get the next connection ID
getNextConnectionId :: LocalEndPoint -> IO ConnectionId
getNextConnectionId endpoint = 
  modifyMVar (endpoint ^. localState) $ \st -> 
    return (nextConnectionId ^+= 1 $ st, st ^. nextConnectionId)

-- | Create a new endpoint
tcpNewEndPoint :: TCPTransport -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
tcpNewEndPoint transport = do 
  endPoint <- modifyMVar (transport ^. transportState) $ \st -> do 
    chan  <- newChan
    state <- newMVar EndPointState { _nextConnectionId    = firstNonReservedConnectionId 
                                   , _pendingCtrlRequests = IntMap.empty
                                   , _nextCtrlRequestId   = 0
                                   }
    let ix   = fromIntegral $ IntMap.size (st ^. localEndPoints) 
    let host = transport ^. transportHost
    let port = transport ^. transportPort
    let addr = EndPointAddress . BSC.pack $ host ++ ":" ++ port ++ ":" ++ show ix 
    let localEndPoint = LocalEndPoint { _localAddress = addr
                                      , _localChannel = chan
                                      , _localState   = state
                                      }
    return ((localEndPointAt ix ^= Just localEndPoint) $ st, localEndPoint)
  return . Right $ EndPoint { receive = readChan (endPoint ^. localChannel) 
                            , address = endPoint ^. localAddress 
                            , connect = tcpConnect transport endPoint 
                            , newMulticastGroup     = return . Left $ newMulticastGroupError 
                            , resolveMulticastGroup = \_ -> return . Left $ resolveMulticastGroupError
                            }
  where
    newMulticastGroupError     = FailedWith NewMulticastGroupUnsupported "TCP does not support multicast" 
    resolveMulticastGroupError = FailedWith ResolveMulticastGroupUnsupported "TCP does not support multicast" 

-- | We reserve a bunch of connection IDs for control messages
firstNonReservedConnectionId :: ConnectionId
firstNonReservedConnectionId = 1024

-- | Connnect to an endpoint
tcpConnect :: TCPTransport     -- ^ Transport 
           -> LocalEndPoint    -- ^ Local end point
           -> EndPointAddress  -- ^ Remote address
           -> Reliability      -- ^ Reliability (ignored)
           -> IO (Either (FailedWith ConnectErrorCode) Connection)
tcpConnect transport ourEndPoint theirAddress _ = runErrorT $ do
    theirEndPoint <- remoteEndPoint transport ourEndPoint theirAddress 
    connId <- requestNewConnection ourEndPoint theirEndPoint 
    let sock = theirEndPoint ^. remoteSocket
    return Connection { send  = runErrorT . 
                                failWithIO (FailedWith SendFailed . show) . 
                                withRemoteLock theirEndPoint .
                                sendMany sock .
                                (\payload -> encodeInt32 connId : prependLength payload)
                      , close = -- TODO: we should not close the TCP connection until all
                                -- lightweight connections have been closed
                                N.sClose sock 
                      }

-- | Request a new connection 
requestNewConnection :: (MonadIO m, MonadError (FailedWith ConnectErrorCode) m) 
                     => LocalEndPoint 
                     -> RemoteEndPoint 
                     -> m ConnectionId
requestNewConnection ourEndPoint theirEndPoint = do
    mcid <- failWithIO (failed . show) $ do
      reply <- newEmptyMVar
      reqId <- modifyMVar state $ \st -> do
        let reqId = st ^. nextCtrlRequestId
        return ((nextCtrlRequestId ^+= 1) . (pendingCtrlRequestsAt reqId ^= Just reply) $ st, reqId)
      withRemoteLock theirEndPoint $ sendMany sock [encodeInt32 RequestConnectionId, encodeInt32 reqId]
      response <- decodeInt32 . BS.concat <$> takeMVar reply
      modifyMVar_ state $ return . (pendingCtrlRequestsAt reqId ^= Nothing)
      return response 
    case mcid of 
      Nothing  -> throwError (failed "Invalid integer") 
      Just cid -> return cid
  where
    sock   = theirEndPoint ^. remoteSocket
    failed = FailedWith ConnectFailed
    state  = ourEndPoint ^. localState 

-- | Find a remote endpoint 
--
-- TODO: hints?
remoteEndPoint :: TCPTransport 
               -> LocalEndPoint 
               -> EndPointAddress
               -> ErrorT (FailedWith ConnectErrorCode) IO RemoteEndPoint
remoteEndPoint transport ourEndPoint theirAddress = do
  mendpoint <- liftIO $ (^. remoteEndPointAt theirAddress) <$> readMVar (transport ^. transportState) 
  case mendpoint of
    Just endpoint -> 
      return endpoint 
    Nothing -> do
      -- Create a new connection
      -- liftIO $ putStrLn $ "Creating socket from " ++ show ourAddress ++ " to " ++ show theirAddress
      (host, port, endPointId) <- failWith (invalidAddress "Could not parse") $
                                  (decodeEndPointAddress theirAddress)
      addr:_ <- failWithIO (invalidAddress . show) $ 
                N.getAddrInfo Nothing (Just host) (Just port) 
      sock   <- failWithIO (insufficientResources . show) $
                N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      liftIO $ N.setSocketOption sock N.ReuseAddr 1
      failWithIO (failed . show) $ N.connect sock (N.addrAddress addr) 
      -- Send the endpoint ID we're interested in and our own address
      failWithIO (failed . show) $ sendMany sock (encodeInt32 endPointId : prependLength [ourAddress]) 
      liftIO $ forkRemoteEndPoint transport ourEndPoint theirAddress sock 
  where
    invalidAddress        = FailedWith ConnectInvalidAddress 
    insufficientResources = FailedWith ConnectInsufficientResources 
    failed                = FailedWith ConnectFailed
    EndPointAddress ourAddress = ourEndPoint ^. localAddress

-- | We must avoid scrambling concurrent sends to the same endpoint
--
-- TODO: deal with exceptions
withRemoteLock :: MonadIO m => RemoteEndPoint -> m a -> m a
withRemoteLock theirEndPoint p = do
  let lock = theirEndPoint ^. remoteLock
  liftIO $ takeMVar lock 
  x <- p
  liftIO $ putMVar lock () 
  return x

-- | Decode end point address
-- TODO: This uses regular expression parsing, which is nice, but unnecessary
decodeEndPointAddress :: EndPointAddress -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) = match endPointAddressRE (BSC.unpack bs) 
  where
    endPointAddressRE :: RE Char (N.HostName, N.ServiceName, EndPointId)
    endPointAddressRE = (,,) <$> few anySym <*> (sym ':' *> few anySym) <*> (sym ':' *> (read <$> many anySym))

--------------------------------------------------------------------------------
-- Lens definitions
--------------------------------------------------------------------------------

transportState :: Lens TCPTransport (MVar TransportState)
transportState = lens _transportState (\st trans -> trans { _transportState = st })

transportHost :: Lens TCPTransport N.HostName
transportHost = lens _transportHost (\host trans -> trans { _transportHost = host })

transportPort :: Lens TCPTransport N.ServiceName
transportPort = lens _transportPort (\port trans -> trans { _transportPort = port })

localEndPoints :: Lens TransportState (IntMap LocalEndPoint)
localEndPoints = lens _localEndPoints (\es st -> st { _localEndPoints = es })

remoteEndPoints :: Lens TransportState (Map EndPointAddress RemoteEndPoint)
remoteEndPoints = lens _remoteEndPoints (\es st -> st { _remoteEndPoints = es })

localAddress :: Lens LocalEndPoint EndPointAddress
localAddress = lens _localAddress (\addr ep -> ep { _localAddress = addr })

localChannel :: Lens LocalEndPoint (Chan Event)
localChannel = lens _localChannel (\ch ep -> ep { _localChannel = ch })

localState :: Lens LocalEndPoint (MVar EndPointState)
localState = lens _localState (\st ep -> ep { _localState = st })

remoteAddress :: Lens RemoteEndPoint EndPointAddress
remoteAddress = lens _remoteAddress (\addr ep -> ep { _remoteAddress = addr })

remoteSocket :: Lens RemoteEndPoint N.Socket
remoteSocket = lens _remoteSocket (\sock ep -> ep { _remoteSocket = sock })

remoteLock :: Lens RemoteEndPoint (MVar ())
remoteLock = lens _remoteLock (\lock ep -> ep { _remoteLock = lock })

nextConnectionId :: Lens EndPointState ConnectionId
nextConnectionId = lens _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

pendingCtrlRequests :: Lens EndPointState (IntMap (MVar [ByteString]))
pendingCtrlRequests = lens _pendingCtrlRequests (\rep st -> st { _pendingCtrlRequests = rep })

nextCtrlRequestId :: Lens EndPointState ControlRequestId 
nextCtrlRequestId = lens _nextCtrlRequestId (\cid st -> st { _nextCtrlRequestId = cid })

localEndPointAt :: EndPointId -> Lens TransportState (Maybe LocalEndPoint)
localEndPointAt ix = localEndPoints >>> intMapLens (fromIntegral ix)

remoteEndPointAt :: EndPointAddress -> Lens TransportState (Maybe RemoteEndPoint)
remoteEndPointAt addr = remoteEndPoints >>> mapLens addr

pendingCtrlRequestsAt :: ControlRequestId -> Lens EndPointState (Maybe (MVar [ByteString]))
pendingCtrlRequestsAt ix = pendingCtrlRequests >>> intMapLens (fromIntegral ix)
