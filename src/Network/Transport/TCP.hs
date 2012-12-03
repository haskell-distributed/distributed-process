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
module Network.Transport.TCP
  ( -- * Main API
    createTransport
  , TCPParameters(..)
  , defaultTCPParameters
    -- * Internals (exposed for unit tests)
  , createTransportExposeInternals
  , TransportInternals(..)
  , EndPointId
  , encodeEndPointAddress
  , decodeEndPointAddress
  , ControlHeader(..)
  , ConnectionRequestResponse(..)
  , firstNonReservedLightweightConnectionId
  , firstNonReservedHeavyweightConnectionId
  , socketToEndPoint
  , LightweightConnectionId
    -- * Design notes
    -- $design
  ) where

import Prelude hiding
  ( mapM_
#if ! MIN_VERSION_base(4,6,0)
  , catch
#endif
  )

import Network.Transport
import Network.Transport.TCP.Internal
  ( forkServer
  , recvWithLength
  , recvInt32
  , tryCloseSocket
  )
import Network.Transport.Internal
  ( encodeInt32
  , prependLength
  , mapIOException
  , tryIO
  , tryToEnum
  , void
  , timeoutMaybe
  , asyncWhenCancelled
  )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket as N
#else
import qualified Network.Socket as N
#endif
  ( HostName
  , ServiceName
  , Socket
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

#ifdef USE_MOCK_NETWORK
import Network.Transport.TCP.Mock.Socket.ByteString (sendMany)
#else
import Network.Socket.ByteString (sendMany)
#endif

import Control.Concurrent (forkIO, ThreadId, killThread, myThreadId)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar
  ( MVar
  , newMVar
  , modifyMVar
  , modifyMVar_
  , readMVar
  , putMVar
  , newEmptyMVar
  , withMVar
  )
import Control.Category ((>>>))
import Control.Applicative ((<$>))
import Control.Monad (when, unless, join)
import Control.Exception
  ( IOException
  , SomeException
  , AsyncException
  , handle
  , throw
  , throwIO
  , try
  , bracketOnError
  , fromException
  , catch
  )
import Data.IORef (IORef, newIORef, writeIORef, readIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Data.Bits (shiftL, (.|.))
import Data.Word (Word32)
import Data.Set (Set)
import qualified Data.Set as Set
  ( empty
  , insert
  , elems
  , singleton
  , null
  , delete
  , member
  )
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe)
import Data.Foldable (forM_, mapM_)

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

-- We use underscores for fields that we might update (using accessors)
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
  { transportHost   :: !N.HostName
  , transportPort   :: !N.ServiceName
  , transportState  :: !(MVar TransportState)
  , transportParams :: !TCPParameters
  }

data TransportState =
    TransportValid !ValidTransportState
  | TransportClosed

data ValidTransportState = ValidTransportState
  { _localEndPoints :: !(Map EndPointAddress LocalEndPoint)
  , _nextEndPointId :: !EndPointId
  }

data LocalEndPoint = LocalEndPoint
  { localAddress :: !EndPointAddress
  , localChannel :: !(Chan Event)
  , localState   :: !(MVar LocalEndPointState)
  }

data LocalEndPointState =
    LocalEndPointValid !ValidLocalEndPointState
  | LocalEndPointClosed

data ValidLocalEndPointState = ValidLocalEndPointState
  { -- Next available ID for an outgoing lightweight self-connection
    -- (see also remoteNextConnOutId)
    _localNextConnOutId :: !LightweightConnectionId
    -- Next available ID for an incoming heavyweight connection
  , _nextConnInId :: !HeavyweightConnectionId
    -- Currently active outgoing heavyweight connections
  , _localConnections :: !(Map EndPointAddress RemoteEndPoint)
  }

-- REMOTE ENDPOINTS
--
-- Remote endpoints (basically, TCP connections) have the following lifecycle:
--
--   Init  ---+---> Invalid
--            |
--            +-------------------------------\
--            |                               |
--            |       /----------\            |
--            |       |          |            |
--            |       v          |            v
--            +---> Valid ---> Closing ---> Closed
--            |       |          |            |
--            |       |          |            v
--            \-------+----------+--------> Failed
--
-- Init: There are two places where we create new remote endpoints: in
--   createConnectionTo (in response to an API 'connect' call) and in
--   handleConnectionRequest (when a remote node tries to connect to us).
--   'Init' carries an MVar () 'resolved' which concurrent threads can use to
--   wait for the remote endpoint to finish initialization. We record who
--   requested the connection (the local endpoint or the remote endpoint).
--
-- Invalid: We put the remote endpoint in invalid state only during
--   createConnectionTo when we fail to connect.
--
-- Valid: This is the "normal" state for a working remote endpoint.
--
-- Closing: When we detect that a remote endpoint is no longer used, we send a
--   CloseSocket request across the connection and put the remote endpoint in
--   closing state. As with Init, 'Closing' carries an MVar () 'resolved' which
--   concurrent threads can use to wait for the remote endpoint to either be
--   closed fully (if the communication parnet responds with another
--   CloseSocket) or be put back in 'Valid' state if the remote endpoint denies
--   the request.
--
--   We also put the endpoint in Closed state, directly from Init, if we our
--   outbound connection request crossed an inbound connection request and we
--   decide to keep the inbound (i.e., the remote endpoint sent us a
--   ConnectionRequestCrossed message).
--
-- Closed: The endpoint is put in Closed state after a successful garbage
--   collection.
--
-- Failed: If the connection to the remote endpoint is lost, or the local
-- endpoint (or the whole transport) is closed manually, the remote endpoint is
-- put in Failed state, and we record the reason.
--
-- Invariants for dealing with remote endpoints:
--
-- INV-SEND: Whenever we send data the remote endpoint must be locked (to avoid
--   interleaving bits of payload).
--
-- INV-CLOSE: Local endpoints should never point to remote endpoint in closed
--   state.  Whenever we put an endpoint in Closed state we remove that
--   endpoint from localConnections first, so that if a concurrent thread reads
--   the MVar, finds RemoteEndPointClosed, and then looks up the endpoint in
--   localConnections it is guaranteed to either find a different remote
--   endpoint, or else none at all (if we don't insist in this order some
--   threads might start spinning).
--
-- INV-RESOLVE: We should only signal on 'resolved' while the remote endpoint is
--   locked, and the remote endpoint must be in Valid or Closed state once
--   unlocked. This guarantees that there will not be two threads attempting to
--   both signal on 'resolved'.
--
-- INV-LOST: If a send or recv fails, or a socket is closed unexpectedly, we
--   first put the remote endpoint in Closed state, and then send a
--   EventConnectionLost event. This guarantees that we only send this event
--   once.
--
-- INV-CLOSING: An endpoint in closing state is for all intents and purposes
--   closed; that is, we shouldn't do any 'send's on it (although 'recv' is
--   acceptable, of course -- as we are waiting for the remote endpoint to
--   confirm or deny the request).
--
-- INV-LOCK-ORDER: Remote endpoint must be locked before their local endpoints.
--   In other words: it is okay to call modifyMVar on a local endpoint inside a
--   modifyMVar on a remote endpoint, but not the other way around. In
--   particular, it is okay to call removeRemoteEndPoint inside
--   modifyRemoteState.

data RemoteEndPoint = RemoteEndPoint
  { remoteAddress   :: !EndPointAddress
  , remoteState     :: !(MVar RemoteState)
  , remoteId        :: !HeavyweightConnectionId
  , remoteScheduled :: !(Chan (IO ()))
  }

data RequestedBy = RequestedByUs | RequestedByThem
  deriving (Eq, Show)

data RemoteState =
    -- | Invalid remote endpoint (for example, invalid address)
    RemoteEndPointInvalid !(TransportError ConnectErrorCode)
    -- | The remote endpoint is being initialized
  | RemoteEndPointInit !(MVar ()) !(MVar ()) !RequestedBy
    -- | "Normal" working endpoint
  | RemoteEndPointValid !ValidRemoteEndPointState
    -- | The remote endpoint is being closed (garbage collected)
  | RemoteEndPointClosing !(MVar ()) !ValidRemoteEndPointState
    -- | The remote endpoint has been closed (garbage collected)
  | RemoteEndPointClosed
    -- | The remote endpoint has failed, or has been forcefully shutdown
    -- using a closeTransport or closeEndPoint API call
  | RemoteEndPointFailed !IOException

-- TODO: we might want to replace Set (here and elsewhere) by faster
-- containers
--
-- TODO: we could get rid of 'remoteIncoming' (and maintain less state) if
-- we introduce a new event 'AllConnectionsClosed'
data ValidRemoteEndPointState = ValidRemoteEndPointState
  { _remoteOutgoing      :: !Int
  , _remoteIncoming      :: !(Set LightweightConnectionId)
  , _remoteMaxIncoming   :: !LightweightConnectionId
  , _remoteNextConnOutId :: !LightweightConnectionId
  ,  remoteSocket        :: !N.Socket
  ,  remoteSendLock      :: !(MVar ())
  }

-- | Local identifier for an endpoint within this transport
type EndPointId = Word32

-- | Pair of local and a remote endpoint (for conciseness in signatures)
type EndPointPair = (LocalEndPoint, RemoteEndPoint)

-- | Lightweight connection ID (sender allocated)
--
-- A ConnectionId is the concentation of a 'HeavyweightConnectionId' and a
-- 'LightweightConnectionId'.
type LightweightConnectionId = Word32

-- | Heavyweight connection ID (recipient allocated)
--
-- A ConnectionId is the concentation of a 'HeavyweightConnectionId' and a
-- 'LightweightConnectionId'.
type HeavyweightConnectionId = Word32

-- | Control headers
data ControlHeader =
    -- | Tell the remote endpoint that we created a new connection
    CreatedNewConnection
    -- | Tell the remote endpoint we will no longer be using a connection
  | CloseConnection
    -- | Request to close the connection (see module description)
  | CloseSocket
  deriving (Enum, Bounded, Show)

-- | Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    -- | /B/ accepts the connection
    ConnectionRequestAccepted
    -- | /A/ requested an invalid endpoint
  | ConnectionRequestInvalid
    -- | /A/s request crossed with a request from /B/ (see protocols)
  | ConnectionRequestCrossed
  deriving (Enum, Bounded, Show)

-- | Parameters for setting up the TCP transport
data TCPParameters = TCPParameters {
    -- | Backlog for 'listen'.
    -- Defaults to SOMAXCONN.
    tcpBacklog :: Int
    -- | Should we set SO_REUSEADDR on the server socket?
    -- Defaults to True.
  , tcpReuseServerAddr :: Bool
    -- | Should we set SO_REUSEADDR on client sockets?
    -- Defaults to True.
  , tcpReuseClientAddr :: Bool
  }

-- | Internal functionality we expose for unit testing
data TransportInternals = TransportInternals
  { -- | The ID of the thread that listens for new incoming connections
    transportThread :: ThreadId
    -- | Find the socket between a local and a remote endpoint
  , socketBetween :: EndPointAddress
                  -> EndPointAddress
                  -> IO N.Socket
  }

--------------------------------------------------------------------------------
-- Top-level functionality                                                    --
--------------------------------------------------------------------------------

-- | Create a TCP transport
createTransport :: N.HostName
                -> N.ServiceName
                -> TCPParameters
                -> IO (Either IOException Transport)
createTransport host port params =
  either Left (Right . fst) <$> createTransportExposeInternals host port params

-- | You should probably not use this function (used for unit testing only)
createTransportExposeInternals
  :: N.HostName
  -> N.ServiceName
  -> TCPParameters
  -> IO (Either IOException (Transport, TransportInternals))
createTransportExposeInternals host port params = do
    state <- newMVar . TransportValid $ ValidTransportState
      { _localEndPoints = Map.empty
      , _nextEndPointId = 0
      }
    let transport = TCPTransport { transportState  = state
                                 , transportHost   = host
                                 , transportPort   = port
                                 , transportParams = params
                                 }
    tryIO $ bracketOnError (forkServer
                             host
                             port
                             (tcpBacklog params)
                             (tcpReuseServerAddr params)
                             (terminationHandler transport)
                             (handleConnectionRequest transport))
                           killThread
                           (mkTransport transport)
  where
    mkTransport :: TCPTransport
                -> ThreadId
                -> IO (Transport, TransportInternals)
    mkTransport transport tid = return
      ( Transport
          { newEndPoint    = apiNewEndPoint transport
          , closeTransport = let evs = [ EndPointClosed
                                       , throw $ userError "Transport closed"
                                       ] in
                             apiCloseTransport transport (Just tid) evs
          }
      , TransportInternals
          { transportThread = tid
          , socketBetween   = internalSocketBetween transport
          }
      )

    terminationHandler :: TCPTransport -> SomeException -> IO ()
    terminationHandler transport ex = do
      let evs = [ ErrorEvent (TransportError EventTransportFailed (show ex))
                , throw $ userError "Transport closed"
                ]
      apiCloseTransport transport Nothing evs

-- | Default TCP parameters
defaultTCPParameters :: TCPParameters
defaultTCPParameters = TCPParameters {
    tcpBacklog         = N.sOMAXCONN
  , tcpReuseServerAddr = True
  , tcpReuseClientAddr = True
  }

--------------------------------------------------------------------------------
-- API functions                                                              --
--------------------------------------------------------------------------------

-- | Close the transport
apiCloseTransport :: TCPTransport -> Maybe ThreadId -> [Event] -> IO ()
apiCloseTransport transport mTransportThread evs =
  asyncWhenCancelled return $ do
    mTSt <- modifyMVar (transportState transport) $ \st -> case st of
      TransportValid vst -> return (TransportClosed, Just vst)
      TransportClosed    -> return (TransportClosed, Nothing)
    forM_ mTSt $ mapM_ (apiCloseEndPoint transport evs) . (^. localEndPoints)
    -- This will invoke the termination handler, which in turn will call
    -- apiCloseTransport again, but then the transport will already be closed
    -- and we won't be passed a transport thread, so we terminate immmediate
    forM_ mTransportThread killThread

-- | Create a new endpoint
apiNewEndPoint :: TCPTransport
               -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint transport =
  try . asyncWhenCancelled closeEndPoint $ do
    ourEndPoint <- createLocalEndPoint transport
    return EndPoint
      { receive       = readChan (localChannel ourEndPoint)
      , address       = localAddress ourEndPoint
      , connect       = apiConnect (transportParams transport) ourEndPoint
      , closeEndPoint = let evs = [ EndPointClosed
                                  , throw $ userError "Endpoint closed"
                                  ] in
                        apiCloseEndPoint transport evs ourEndPoint
      , newMulticastGroup     = return . Left $ newMulticastGroupError
      , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
      }
  where
    newMulticastGroupError =
      TransportError NewMulticastGroupUnsupported "Multicast not supported"
    resolveMulticastGroupError =
      TransportError ResolveMulticastGroupUnsupported "Multicast not supported"

-- | Connnect to an endpoint
apiConnect :: TCPParameters    -- ^ Parameters
           -> LocalEndPoint    -- ^ Local end point
           -> EndPointAddress  -- ^ Remote address
           -> Reliability      -- ^ Reliability (ignored)
           -> ConnectHints     -- ^ Hints
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect params ourEndPoint theirAddress _reliability hints =
  try . asyncWhenCancelled close $
    if localAddress ourEndPoint == theirAddress
      then connectToSelf ourEndPoint
      else do
        resetIfBroken ourEndPoint theirAddress
        (theirEndPoint, connId) <-
          createConnectionTo params ourEndPoint theirAddress hints
        -- connAlive can be an IORef rather than an MVar because it is protected
        -- by the remoteState MVar. We don't need the overhead of locking twice.
        connAlive <- newIORef True
        return Connection
          { send  = apiSend  (ourEndPoint, theirEndPoint) connId connAlive
          , close = apiClose (ourEndPoint, theirEndPoint) connId connAlive
          }

-- | Close a connection
apiClose :: EndPointPair -> LightweightConnectionId -> IORef Bool -> IO ()
apiClose (ourEndPoint, theirEndPoint) connId connAlive =
  void . tryIO . asyncWhenCancelled return $ do
    mAct <- modifyMVar (remoteState theirEndPoint) $ \st -> case st of
      RemoteEndPointValid vst -> do
        alive <- readIORef connAlive
        if alive
          then do
            writeIORef connAlive False
            act <- schedule theirEndPoint $
              sendOn vst [encodeInt32 CloseConnection, encodeInt32 connId]
            return ( RemoteEndPointValid
                   . (remoteOutgoing ^: (\x -> x - 1))
                   $ vst
                   , Just act
                   )
          else
            return (RemoteEndPointValid vst, Nothing)
      _ ->
        return (st, Nothing)
    forM_ mAct $ runScheduledAction (ourEndPoint, theirEndPoint)
    closeIfUnused (ourEndPoint, theirEndPoint)


-- | Send data across a connection
apiSend :: EndPointPair             -- ^ Local and remote endpoint
        -> LightweightConnectionId  -- ^ Connection ID
        -> IORef Bool               -- ^ Is the connection still alive?
        -> [ByteString]             -- ^ Payload
        -> IO (Either (TransportError SendErrorCode) ())
apiSend (ourEndPoint, theirEndPoint) connId connAlive payload =
    -- We don't need the overhead of asyncWhenCancelled here
    try . mapIOException sendFailed $ do
      act <- withMVar (remoteState theirEndPoint) $ \st -> case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint) "apiSend"
        RemoteEndPointInit _ _ _ ->
          relyViolation (ourEndPoint, theirEndPoint) "apiSend"
        RemoteEndPointValid vst -> do
          alive <- readIORef connAlive
          if alive
            then schedule theirEndPoint $
              sendOn vst (encodeInt32 connId : prependLength payload)
            else throwIO $ TransportError SendClosed "Connection closed"
        RemoteEndPointClosing _ _ -> do
          alive <- readIORef connAlive
          if alive
            then relyViolation (ourEndPoint, theirEndPoint) "apiSend"
            else throwIO $ TransportError SendClosed "Connection closed"
        RemoteEndPointClosed -> do
          alive <- readIORef connAlive
          if alive
            then relyViolation (ourEndPoint, theirEndPoint) "apiSend"
            else throwIO $ TransportError SendClosed "Connection closed"
        RemoteEndPointFailed err -> do
          alive <- readIORef connAlive
          if alive
            then throwIO $ TransportError SendFailed (show err)
            else throwIO $ TransportError SendClosed "Connection closed"
      runScheduledAction (ourEndPoint, theirEndPoint) act
  where
    sendFailed = TransportError SendFailed . show

-- | Force-close the endpoint
apiCloseEndPoint :: TCPTransport    -- ^ Transport
                 -> [Event]         -- ^ Events used to report closure
                 -> LocalEndPoint   -- ^ Local endpoint
                 -> IO ()
apiCloseEndPoint transport evs ourEndPoint =
  asyncWhenCancelled return $ do
    -- Remove the reference from the transport state
    removeLocalEndPoint transport ourEndPoint
    -- Close the local endpoint
    mOurState <- modifyMVar (localState ourEndPoint) $ \st ->
      case st of
        LocalEndPointValid vst ->
          return (LocalEndPointClosed, Just vst)
        LocalEndPointClosed ->
          return (LocalEndPointClosed, Nothing)
    forM_ mOurState $ \vst -> do
      forM_ (vst ^. localConnections) tryCloseRemoteSocket
      forM_ evs $ writeChan (localChannel ourEndPoint)
  where
    -- Close the remote socket and return the set of all incoming connections
    tryCloseRemoteSocket :: RemoteEndPoint -> IO ()
    tryCloseRemoteSocket theirEndPoint = do
      -- We make an attempt to close the connection nicely
      -- (by sending a CloseSocket first)
      let closed = RemoteEndPointFailed . userError $ "apiCloseEndPoint"
      mAct <- modifyMVar (remoteState theirEndPoint) $ \st ->
        case st of
          RemoteEndPointInvalid _ ->
            return (st, Nothing)
          RemoteEndPointInit resolved _ _ -> do
            putMVar resolved ()
            return (closed, Nothing)
          RemoteEndPointValid vst -> do
            act <- schedule theirEndPoint $ do
              tryIO $ sendOn vst [ encodeInt32 CloseSocket
                                 , encodeInt32 (vst ^. remoteMaxIncoming)
                                 ]
              tryCloseSocket (remoteSocket vst)
            return (closed, Just act)
          RemoteEndPointClosing resolved vst -> do
            putMVar resolved ()
            act <- schedule theirEndPoint $ tryCloseSocket (remoteSocket vst)
            return (closed, Just act)
          RemoteEndPointClosed ->
            return (st, Nothing)
          RemoteEndPointFailed err ->
            return (RemoteEndPointFailed err, Nothing)
      forM_ mAct $ runScheduledAction (ourEndPoint, theirEndPoint)


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
handleConnectionRequest transport sock = handle handleException $ do
    ourEndPointId <- recvInt32 sock
    theirAddress  <- EndPointAddress . BS.concat <$> recvWithLength sock
    let ourAddress = encodeEndPointAddress (transportHost transport)
                                           (transportPort transport)
                                           ourEndPointId
    ourEndPoint <- withMVar (transportState transport) $ \st -> case st of
      TransportValid vst ->
        case vst ^. localEndPointAt ourAddress of
          Nothing -> do
            sendMany sock [encodeInt32 ConnectionRequestInvalid]
            throwIO $ userError "handleConnectionRequest: Invalid endpoint"
          Just ourEndPoint ->
            return ourEndPoint
      TransportClosed ->
        throwIO $ userError "Transport closed"
    void . forkIO $ go ourEndPoint theirAddress
  where
    go :: LocalEndPoint -> EndPointAddress -> IO ()
    go ourEndPoint theirAddress = do
      -- This runs in a thread that will never be killed
      mEndPoint <- handle ((>> return Nothing) . handleException) $ do
        resetIfBroken ourEndPoint theirAddress
        (theirEndPoint, isNew) <-
          findRemoteEndPoint ourEndPoint theirAddress RequestedByThem

        if not isNew
          then do
            tryIO $ sendMany sock [encodeInt32 ConnectionRequestCrossed]
            tryCloseSocket sock
            return Nothing
          else do
            sendLock <- newMVar ()
            let vst = ValidRemoteEndPointState
                        {  remoteSocket        = sock
                        ,  remoteSendLock      = sendLock
                        , _remoteOutgoing      = 0
                        , _remoteIncoming      = Set.empty
                        , _remoteMaxIncoming   = 0
                        , _remoteNextConnOutId = firstNonReservedLightweightConnectionId
                        }
            sendMany sock [encodeInt32 ConnectionRequestAccepted]
            resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointValid vst)
            return (Just theirEndPoint)
      -- If we left the scope of the exception handler with a return value of
      -- Nothing then the socket is already closed; otherwise, the socket has
      -- been recorded as part of the remote endpoint. Either way, we no longer
      -- have to worry about closing the socket on receiving an asynchronous
      -- exception from this point forward.
      forM_ mEndPoint $ handleIncomingMessages . (,) ourEndPoint

    handleException :: SomeException -> IO ()
    handleException ex = do
      tryCloseSocket sock
      rethrowIfAsync (fromException ex)

    rethrowIfAsync :: Maybe AsyncException -> IO ()
    rethrowIfAsync = mapM_ throwIO

-- | Handle requests from a remote endpoint.
--
-- Returns only if the remote party closes the socket or if an error occurs.
-- This runs in a thread that will never be killed.
handleIncomingMessages :: EndPointPair -> IO ()
handleIncomingMessages (ourEndPoint, theirEndPoint) = do
    mSock <- withMVar theirState $ \st ->
      case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint)
            "handleIncomingMessages (invalid)"
        RemoteEndPointInit _ _ _ ->
          relyViolation (ourEndPoint, theirEndPoint)
            "handleIncomingMessages (init)"
        RemoteEndPointValid ep ->
          return . Just $ remoteSocket ep
        RemoteEndPointClosing _ ep ->
          return . Just $ remoteSocket ep
        RemoteEndPointClosed ->
          return Nothing
        RemoteEndPointFailed _ ->
          return Nothing

    forM_ mSock $ \sock ->
      tryIO (go sock) >>= either (prematureExit sock) return
  where
    -- Dispatch
    --
    -- If a recv throws an exception this will be caught top-level and
    -- 'prematureExit' will be invoked. The same will happen if the remote
    -- endpoint is put into a Closed (or Closing) state by a concurrent thread
    -- (because a 'send' failed) -- the individual handlers below will throw a
    -- user exception which is then caught and handled the same way as an
    -- exception thrown by 'recv'.
    go :: N.Socket -> IO ()
    go sock = do
      lcid <- recvInt32 sock :: IO LightweightConnectionId
      if lcid >= firstNonReservedLightweightConnectionId
        then do
          readMessage sock lcid
          go sock
        else
          case tryToEnum (fromIntegral lcid) of
            Just CreatedNewConnection -> do
              recvInt32 sock >>= createdNewConnection
              go sock
            Just CloseConnection -> do
              recvInt32 sock >>= closeConnection
              go sock
            Just CloseSocket -> do
              didClose <- recvInt32 sock >>= closeSocket sock
              unless didClose $ go sock
            Nothing ->
              throwIO $ userError "Invalid control request"

    -- Create a new connection
    createdNewConnection :: LightweightConnectionId -> IO ()
    createdNewConnection lcid = do
      modifyMVar_ theirState $ \st -> do
        vst <- case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:createNewConnection (invalid)"
          RemoteEndPointInit _ _ _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:createNewConnection (init)"
          RemoteEndPointValid vst ->
            return ( (remoteIncoming ^: Set.insert lcid)
                   $ (remoteMaxIncoming ^= lcid)
                   vst
                   )
          RemoteEndPointClosing resolved vst -> do
            -- If the endpoint is in closing state that means we send a
            -- CloseSocket request to the remote endpoint. If the remote
            -- endpoint replies that it created a new connection, it either
            -- ignored our request or it sent the request before it got ours.
            -- Either way, at this point we simply restore the endpoint to
            -- RemoteEndPointValid
            putMVar resolved ()
            return ( (remoteIncoming ^= Set.singleton lcid)
                   . (remoteMaxIncoming ^= lcid)
                   $ vst
                   )
          RemoteEndPointFailed err ->
            throwIO err
          RemoteEndPointClosed ->
            relyViolation (ourEndPoint, theirEndPoint)
              "createNewConnection (closed)"
        return (RemoteEndPointValid vst)
      writeChan ourChannel (ConnectionOpened (connId lcid) ReliableOrdered theirAddr)

    -- Close a connection
    -- It is important that we verify that the connection is in fact open,
    -- because otherwise we should not decrement the reference count
    closeConnection :: LightweightConnectionId -> IO ()
    closeConnection lcid = do
      modifyMVar_ theirState $ \st -> case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection (invalid)"
        RemoteEndPointInit _ _ _ ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection (init)"
        RemoteEndPointValid vst -> do
          unless (Set.member lcid (vst ^. remoteIncoming)) $
            throwIO $ userError "Invalid CloseConnection"
          return ( RemoteEndPointValid
                 . (remoteIncoming ^: Set.delete lcid)
                 $ vst
                 )
        RemoteEndPointClosing _ _ ->
          -- If the remote endpoint is in Closing state, that means that are as
          -- far as we are concerned there are no incoming connections. This
          -- means that a CloseConnection request at this point is invalid.
          throwIO $ userError "Invalid CloseConnection request"
        RemoteEndPointFailed err ->
          throwIO err
        RemoteEndPointClosed ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection (closed)"
      writeChan ourChannel (ConnectionClosed (connId lcid))

    -- Close the socket (if we don't have any outgoing connections)
    closeSocket :: N.Socket -> LightweightConnectionId -> IO Bool
    closeSocket sock lastReceivedId = do
      mAct <- modifyMVar theirState $ \st -> do
        case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:closeSocket (invalid)"
          RemoteEndPointInit _ _ _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:closeSocket (init)"
          RemoteEndPointValid vst -> do
            -- We regard a CloseSocket message as an (optimized) way for the
            -- remote endpoint to indicate that all its connections to us are
            -- now properly closed
            forM_ (Set.elems $ vst ^. remoteIncoming) $
              writeChan ourChannel . ConnectionClosed . connId
            let vst' = remoteIncoming ^= Set.empty $ vst
            -- If we still have outgoing connections then we ignore the
            -- CloseSocket request (we sent a ConnectionCreated message to the
            -- remote endpoint, but it did not receive it before sending the
            -- CloseSocket request). Similarly, if lastReceivedId < lastSentId
            -- then we sent a ConnectionCreated *AND* a ConnectionClosed
            -- message to the remote endpoint, *both of which* it did not yet
            -- receive before sending the CloseSocket request.
            if vst' ^. remoteOutgoing > 0 || lastReceivedId < lastSentId vst
              then
                return (RemoteEndPointValid vst', Nothing)
              else do
                removeRemoteEndPoint (ourEndPoint, theirEndPoint)
                -- Attempt to reply (but don't insist)
                act <- schedule theirEndPoint $ do
                  tryIO $ sendOn vst' [ encodeInt32 CloseSocket
                                      , encodeInt32 (vst ^. remoteMaxIncoming)
                                      ]
                  tryCloseSocket sock
                return (RemoteEndPointClosed, Just act)
          RemoteEndPointClosing resolved vst ->  do
            -- Like above, we need to check if there is a ConnectionCreated
            -- message that we sent but that the remote endpoint has not yet
            -- received. However, since we are in 'closing' state, the only
            -- way this may happen is when we sent a ConnectionCreated,
            -- ConnectionClosed, and CloseSocket message, none of which have
            -- yet been received. We leave the endpoint in closing state in
            -- that case.
            if lastReceivedId < lastSentId vst
              then do
                return (RemoteEndPointClosing resolved vst, Nothing)
              else do
                removeRemoteEndPoint (ourEndPoint, theirEndPoint)
                act <- schedule theirEndPoint $ tryCloseSocket sock
                putMVar resolved ()
                return (RemoteEndPointClosed, Just act)
          RemoteEndPointFailed err ->
            throwIO err
          RemoteEndPointClosed ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:closeSocket (closed)"
      case mAct of
        Nothing -> return False
        Just act -> do
          runScheduledAction (ourEndPoint, theirEndPoint) act
          return True

    -- Read a message and output it on the endPoint's channel. By rights we
    -- should verify that the connection ID is valid, but this is unnecessary
    -- overhead
    readMessage :: N.Socket -> LightweightConnectionId -> IO ()
    readMessage sock lcid =
      recvWithLength sock >>= writeChan ourChannel . Received (connId lcid)

    -- Arguments
    ourChannel  = localChannel ourEndPoint
    theirState  = remoteState theirEndPoint
    theirAddr   = remoteAddress theirEndPoint

    -- Deal with a premature exit
    prematureExit :: N.Socket -> IOException -> IO ()
    prematureExit sock err = do
      tryCloseSocket sock
      modifyMVar_ theirState $ \st ->
        case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:prematureExit"
          RemoteEndPointInit _ _ _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:prematureExit"
          RemoteEndPointValid _ -> do
            let code = EventConnectionLost (remoteAddress theirEndPoint)
            writeChan ourChannel . ErrorEvent $ TransportError code (show err)
            return (RemoteEndPointFailed err)
          RemoteEndPointClosing resolved _ -> do
            putMVar resolved ()
            return (RemoteEndPointFailed err)
          RemoteEndPointClosed ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:prematureExit"
          RemoteEndPointFailed err' ->
            return (RemoteEndPointFailed err')

    -- Construct a connection ID
    connId :: LightweightConnectionId -> ConnectionId
    connId = createConnectionId (remoteId theirEndPoint)

    -- The ID of the last connection _we_ created (or 0 for none)
    lastSentId :: ValidRemoteEndPointState -> LightweightConnectionId
    lastSentId vst =
      if vst ^. remoteNextConnOutId == firstNonReservedLightweightConnectionId
        then 0
        else (vst ^. remoteNextConnOutId) - 1

--------------------------------------------------------------------------------
-- Uninterruptable auxiliary functions                                        --
--                                                                            --
-- All these functions assume they are running in a thread which will never   --
-- be killed.
--------------------------------------------------------------------------------

-- | Create a connection to a remote endpoint
--
-- If the remote endpoint is in 'RemoteEndPointClosing' state then we will
-- block until that is resolved.
--
-- May throw a TransportError ConnectErrorCode exception.
createConnectionTo :: TCPParameters
                    -> LocalEndPoint
                    -> EndPointAddress
                    -> ConnectHints
                    -> IO (RemoteEndPoint, LightweightConnectionId)
createConnectionTo params ourEndPoint theirAddress hints = go
  where
    go = do
      (theirEndPoint, isNew) <- mapIOException connectFailed $
        findRemoteEndPoint ourEndPoint theirAddress RequestedByUs

      if isNew
        then do
          forkIO . handle absorbAllExceptions $
            setupRemoteEndPoint params (ourEndPoint, theirEndPoint) hints
          go
        else do
          -- 'findRemoteEndPoint' will have increased 'remoteOutgoing'
          mapIOException connectFailed $ do
            act <- modifyMVar (remoteState theirEndPoint) $ \st -> case st of
              RemoteEndPointValid vst -> do
                let connId = vst ^. remoteNextConnOutId
                act <- schedule theirEndPoint $ do
                  sendOn vst [encodeInt32 CreatedNewConnection, encodeInt32 connId]
                  return connId
                return ( RemoteEndPointValid
                       $ remoteNextConnOutId ^= connId + 1
                       $ vst
                       , act
                       )
              -- Error cases
              RemoteEndPointInvalid err ->
                throwIO err
              RemoteEndPointFailed err ->
                throwIO err
              -- Algorithmic errors
              _ ->
                relyViolation (ourEndPoint, theirEndPoint) "createConnectionTo"
            -- TODO: deal with exception case?
            connId <- runScheduledAction (ourEndPoint, theirEndPoint) act
            return (theirEndPoint, connId)


    connectFailed :: IOException -> TransportError ConnectErrorCode
    connectFailed = TransportError ConnectFailed . show

    absorbAllExceptions :: SomeException -> IO ()
    absorbAllExceptions _ex =
      return ()

-- | Set up a remote endpoint
setupRemoteEndPoint :: TCPParameters -> EndPointPair -> ConnectHints -> IO ()
setupRemoteEndPoint params (ourEndPoint, theirEndPoint) hints = do
    result <- socketToEndPoint ourAddress
                               theirAddress
                               (tcpReuseClientAddr params)
                               (connectTimeout hints)
    didAccept <- case result of
      Right (sock, ConnectionRequestAccepted) -> do
        sendLock <- newMVar ()
        let vst = ValidRemoteEndPointState
                    {  remoteSocket        = sock
                    ,  remoteSendLock      = sendLock
                    , _remoteOutgoing      = 0
                    , _remoteIncoming      = Set.empty
                    , _remoteMaxIncoming   = 0
                    , _remoteNextConnOutId = firstNonReservedLightweightConnectionId
                    }
        resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointValid vst)
        return True
      Right (sock, ConnectionRequestInvalid) -> do
        let err = invalidAddress "setupRemoteEndPoint: Invalid endpoint"
        resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointInvalid err)
        tryCloseSocket sock
        return False
      Right (sock, ConnectionRequestCrossed) -> do
        withMVar (remoteState theirEndPoint) $ \st -> case st of
          RemoteEndPointInit _ crossed _ ->
            putMVar crossed ()
          RemoteEndPointFailed ex ->
            throwIO ex
          _ ->
            relyViolation (ourEndPoint, theirEndPoint) "setupRemoteEndPoint: Crossed"
        tryCloseSocket sock
        return False
      Left err -> do
        resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointInvalid err)
        return False

    when didAccept $ handleIncomingMessages (ourEndPoint, theirEndPoint)
  where
    ourAddress      = localAddress ourEndPoint
    theirAddress    = remoteAddress theirEndPoint
    invalidAddress  = TransportError ConnectNotFound

-- | Send a CloseSocket request if the remote endpoint is unused
closeIfUnused :: EndPointPair -> IO ()
closeIfUnused (ourEndPoint, theirEndPoint) = do
  mAct <- modifyMVar (remoteState theirEndPoint) $ \st -> case st of
    RemoteEndPointValid vst ->
      if vst ^. remoteOutgoing == 0 && Set.null (vst ^. remoteIncoming)
        then do
          resolved <- newEmptyMVar
          act <- schedule theirEndPoint $
            sendOn vst [ encodeInt32 CloseSocket
                       , encodeInt32 (vst ^. remoteMaxIncoming)
                       ]
          return (RemoteEndPointClosing resolved vst, Just act)
        else
          return (RemoteEndPointValid vst, Nothing)
    _ ->
      return (st, Nothing)
  forM_ mAct $ runScheduledAction (ourEndPoint, theirEndPoint)

-- | Reset a remote endpoint if it is in Invalid mode
--
-- If the remote endpoint is currently in broken state, and
--
--   - a user calls the API function 'connect', or and the remote endpoint is
--   - an inbound connection request comes in from this remote address
--
-- we remove the remote endpoint first.
--
-- Throws a TransportError ConnectFailed exception if the local endpoint is
-- closed.
resetIfBroken :: LocalEndPoint -> EndPointAddress -> IO ()
resetIfBroken ourEndPoint theirAddress = do
  mTheirEndPoint <- withMVar (localState ourEndPoint) $ \st -> case st of
    LocalEndPointValid vst ->
      return (vst ^. localConnectionTo theirAddress)
    LocalEndPointClosed ->
      throwIO $ TransportError ConnectFailed "Endpoint closed"
  forM_ mTheirEndPoint $ \theirEndPoint ->
    withMVar (remoteState theirEndPoint) $ \st -> case st of
      RemoteEndPointInvalid _ ->
        removeRemoteEndPoint (ourEndPoint, theirEndPoint)
      RemoteEndPointFailed _ ->
        removeRemoteEndPoint (ourEndPoint, theirEndPoint)
      _ ->
        return ()

-- | Special case of 'apiConnect': connect an endpoint to itself
--
-- May throw a TransportError ConnectErrorCode (if the local endpoint is closed)
connectToSelf :: LocalEndPoint
               -> IO Connection
connectToSelf ourEndPoint = do
    connAlive <- newIORef True  -- Protected by the local endpoint lock
    lconnId   <- mapIOException connectFailed $ getLocalNextConnOutId ourEndPoint
    let connId = createConnectionId heavyweightSelfConnectionId lconnId
    writeChan ourChan $
      ConnectionOpened connId ReliableOrdered (localAddress ourEndPoint)
    return Connection
      { send  = selfSend connAlive connId
      , close = selfClose connAlive connId
      }
  where
    selfSend :: IORef Bool
             -> ConnectionId
             -> [ByteString]
             -> IO (Either (TransportError SendErrorCode) ())
    selfSend connAlive connId msg =
      try . withMVar ourState $ \st -> case st of
        LocalEndPointValid _ -> do
          alive <- readIORef connAlive
          if alive
            then writeChan ourChan (Received connId msg)
            else throwIO $ TransportError SendClosed "Connection closed"
        LocalEndPointClosed ->
          throwIO $ TransportError SendFailed "Endpoint closed"

    selfClose :: IORef Bool -> ConnectionId -> IO ()
    selfClose connAlive connId =
      withMVar ourState $ \st -> case st of
        LocalEndPointValid _ -> do
          alive <- readIORef connAlive
          when alive $ do
            writeChan ourChan (ConnectionClosed connId)
            writeIORef connAlive False
        LocalEndPointClosed ->
          return ()

    ourChan  = localChannel ourEndPoint
    ourState = localState ourEndPoint
    connectFailed = TransportError ConnectFailed . show

-- | Resolve an endpoint currently in 'Init' state
resolveInit :: EndPointPair -> RemoteState -> IO ()
resolveInit (ourEndPoint, theirEndPoint) newState =
  modifyMVar_ (remoteState theirEndPoint) $ \st -> case st of
    RemoteEndPointInit resolved _ _ -> do
      putMVar resolved ()
      case newState of
        RemoteEndPointClosed ->
          removeRemoteEndPoint (ourEndPoint, theirEndPoint)
        _ ->
          return ()
      return newState
    RemoteEndPointFailed ex ->
      throwIO ex
    _ ->
      relyViolation (ourEndPoint, theirEndPoint) "resolveInit"

-- | Get the next outgoing self-connection ID
--
-- Throws an IO exception when the endpoint is closed.
getLocalNextConnOutId :: LocalEndPoint -> IO LightweightConnectionId
getLocalNextConnOutId ourEndpoint =
  modifyMVar (localState ourEndpoint) $ \st -> case st of
    LocalEndPointValid vst -> do
      let connId = vst ^. localNextConnOutId
      return ( LocalEndPointValid
             . (localNextConnOutId ^= connId + 1)
             $ vst
             , connId)
    LocalEndPointClosed ->
      throwIO $ userError "Local endpoint closed"

-- | Create a new local endpoint
--
-- May throw a TransportError NewEndPointErrorCode exception if the transport
-- is closed.
createLocalEndPoint :: TCPTransport -> IO LocalEndPoint
createLocalEndPoint transport = do
    chan  <- newChan
    state <- newMVar . LocalEndPointValid $ ValidLocalEndPointState
      { _localNextConnOutId = firstNonReservedLightweightConnectionId
      , _localConnections   = Map.empty
      , _nextConnInId       = firstNonReservedHeavyweightConnectionId
      }
    modifyMVar (transportState transport) $ \st -> case st of
      TransportValid vst -> do
        let ix   = vst ^. nextEndPointId
        let addr = encodeEndPointAddress (transportHost transport)
                                         (transportPort transport)
                                         ix
        let localEndPoint = LocalEndPoint { localAddress  = addr
                                          , localChannel  = chan
                                          , localState    = state
                                          }
        return ( TransportValid
               . (localEndPointAt addr ^= Just localEndPoint)
               . (nextEndPointId ^= ix + 1)
               $ vst
               , localEndPoint
               )
      TransportClosed ->
        throwIO (TransportError NewEndPointFailed "Transport closed")


-- | Remove reference to a remote endpoint from a local endpoint
--
-- If the local endpoint is closed, do nothing
removeRemoteEndPoint :: EndPointPair -> IO ()
removeRemoteEndPoint (ourEndPoint, theirEndPoint) =
    modifyMVar_ ourState $ \st -> case st of
      LocalEndPointValid vst ->
        case vst ^. localConnectionTo theirAddress of
          Nothing ->
            return st
          Just remoteEndPoint' ->
            if remoteId remoteEndPoint' == remoteId theirEndPoint
              then return
                ( LocalEndPointValid
                . (localConnectionTo (remoteAddress theirEndPoint) ^= Nothing)
                $ vst
                )
              else return st
      LocalEndPointClosed ->
        return LocalEndPointClosed
  where
    ourState     = localState ourEndPoint
    theirAddress = remoteAddress theirEndPoint

-- | Remove reference to a local endpoint from the transport state
--
-- Does nothing if the transport is closed
removeLocalEndPoint :: TCPTransport -> LocalEndPoint -> IO ()
removeLocalEndPoint transport ourEndPoint =
  modifyMVar_ (transportState transport) $ \st -> case st of
    TransportValid vst ->
      return ( TransportValid
             . (localEndPointAt (localAddress ourEndPoint) ^= Nothing)
             $ vst
             )
    TransportClosed ->
      return TransportClosed

-- | Find a remote endpoint. If the remote endpoint does not yet exist we
-- create it in Init state. Returns if the endpoint was new.
findRemoteEndPoint
  :: LocalEndPoint
  -> EndPointAddress
  -> RequestedBy
  -> IO (RemoteEndPoint, Bool)
findRemoteEndPoint ourEndPoint theirAddress findOrigin = go
  where
    go = do
      (theirEndPoint, isNew) <- modifyMVar ourState $ \st -> case st of
        LocalEndPointValid vst -> case vst ^. localConnectionTo theirAddress of
          Just theirEndPoint ->
            return (st, (theirEndPoint, False))
          Nothing -> do
            resolved   <- newEmptyMVar
            crossed    <- newEmptyMVar
            theirState <- newMVar (RemoteEndPointInit resolved crossed findOrigin)
            scheduled  <- newChan
            let theirEndPoint = RemoteEndPoint
                                  { remoteAddress   = theirAddress
                                  , remoteState     = theirState
                                  , remoteId        = vst ^. nextConnInId
                                  , remoteScheduled = scheduled
                                  }
            return ( LocalEndPointValid
                   . (localConnectionTo theirAddress ^= Just theirEndPoint)
                   . (nextConnInId ^: (+ 1))
                   $ vst
                   , (theirEndPoint, True)
                   )
        LocalEndPointClosed ->
          throwIO $ userError "Local endpoint closed"

      if isNew
        then
          return (theirEndPoint, True)
        else do
          let theirState = remoteState theirEndPoint
          snapshot <- modifyMVar theirState $ \st -> case st of
            RemoteEndPointValid vst ->
              case findOrigin of
                RequestedByUs -> do
                  let st' = RemoteEndPointValid
                          . (remoteOutgoing ^: (+ 1))
                          $ vst
                  return (st', st')
                RequestedByThem ->
                  return (st, st)
            _ ->
              return (st, st)
          -- The snapshot may no longer be up to date at this point, but if we
          -- increased the refcount then it can only either be Valid or Failed
          -- (after an explicit call to 'closeEndPoint' or 'closeTransport')
          case snapshot of
            RemoteEndPointInvalid err ->
              throwIO err
            RemoteEndPointInit resolved crossed initOrigin ->
              case (findOrigin, initOrigin) of
                (RequestedByUs, RequestedByUs) ->
                  readMVar resolved >> go
                (RequestedByUs, RequestedByThem) ->
                  readMVar resolved >> go
                (RequestedByThem, RequestedByUs) ->
                  if ourAddress > theirAddress
                    then do
                      -- Wait for the Crossed message
                      readMVar crossed
                      return (theirEndPoint, True)
                    else
                      return (theirEndPoint, False)
                (RequestedByThem, RequestedByThem) ->
                  throwIO $ userError "Already connected"
            RemoteEndPointValid _ ->
              -- We assume that the request crossed if we find the endpoint in
              -- Valid state. It is possible that this is really an invalid
              -- request, but only in the case of a broken client (we don't
              -- maintain enough history to be able to tell the difference).
              return (theirEndPoint, False)
            RemoteEndPointClosing resolved _ ->
              readMVar resolved >> go
            RemoteEndPointClosed ->
              go
            RemoteEndPointFailed err ->
              throwIO err

    ourState   = localState ourEndPoint
    ourAddress = localAddress ourEndPoint

-- | Send a payload over a heavyweight connection (thread safe)
sendOn :: ValidRemoteEndPointState -> [ByteString] -> IO ()
sendOn vst bs = withMVar (remoteSendLock vst) $ \() ->
  sendMany (remoteSocket vst) bs

--------------------------------------------------------------------------------
-- Scheduling actions                                                         --
--------------------------------------------------------------------------------

-- | See 'schedule'/'runScheduledAction'
type Action a = MVar (Either SomeException a)

-- | Schedule an action to be executed (see also 'runScheduledAction')
schedule :: RemoteEndPoint -> IO a -> IO (Action a)
schedule theirEndPoint act = do
  mvar <- newEmptyMVar
  writeChan (remoteScheduled theirEndPoint) $
    catch (act >>= putMVar mvar . Right) (putMVar mvar . Left)
  return mvar

-- | Run a scheduled action. Every call to 'schedule' should be paired with a
-- call to 'runScheduledAction' so that every scheduled action is run. Note
-- however that the there is no guarantee that in
--
-- > do act <- schedule p
-- >    runScheduledAction
--
-- 'runScheduledAction' will run @p@ (it might run some other scheduled action).
-- However, it will then wait until @p@ is executed (by this call to
-- 'runScheduledAction' or by another).
runScheduledAction :: EndPointPair -> Action a -> IO a
runScheduledAction (ourEndPoint, theirEndPoint) mvar = do
    join $ readChan (remoteScheduled theirEndPoint)
    ma <- readMVar mvar
    case ma of
      Right a -> return a
      Left e -> do
        forM_ (fromException e) $ \ioe ->
          modifyMVar_ (remoteState theirEndPoint) $ \st ->
            case st of
              RemoteEndPointValid vst -> handleIOException ioe vst
              _ -> return (RemoteEndPointFailed ioe)
        throwIO e
  where
    handleIOException :: IOException
                      -> ValidRemoteEndPointState
                      -> IO RemoteState
    handleIOException ex vst = do
      tryCloseSocket (remoteSocket vst)
      let code     = EventConnectionLost (remoteAddress theirEndPoint)
          err      = TransportError code (show ex)
      writeChan (localChannel ourEndPoint) $ ErrorEvent err
      return (RemoteEndPointFailed ex)

--------------------------------------------------------------------------------
-- "Stateless" (MVar free) functions                                          --
--------------------------------------------------------------------------------

-- | Establish a connection to a remote endpoint
--
-- Maybe throw a TransportError
socketToEndPoint :: EndPointAddress -- ^ Our address
                 -> EndPointAddress -- ^ Their address
                 -> Bool            -- ^ Use SO_REUSEADDR?
                 -> Maybe Int       -- ^ Timeout for connect
                 -> IO (Either (TransportError ConnectErrorCode)
                               (N.Socket, ConnectionRequestResponse))
socketToEndPoint (EndPointAddress ourAddress) theirAddress reuseAddr timeout =
  try $ do
    (host, port, theirEndPointId) <- case decodeEndPointAddress theirAddress of
      Nothing  -> throwIO (failed . userError $ "Could not parse")
      Just dec -> return dec
    addr:_ <- mapIOException invalidAddress $
      N.getAddrInfo Nothing (Just host) (Just port)
    bracketOnError (createSocket addr) tryCloseSocket $ \sock -> do
      when reuseAddr $
        mapIOException failed $ N.setSocketOption sock N.ReuseAddr 1
      mapIOException invalidAddress $
        timeoutMaybe timeout timeoutError $
          N.connect sock (N.addrAddress addr)
      response <- mapIOException failed $ do
        sendMany sock (encodeInt32 theirEndPointId : prependLength [ourAddress])
        recvInt32 sock
      case tryToEnum response of
        Nothing -> throwIO (failed . userError $ "Unexpected response")
        Just r  -> return (sock, r)
  where
    createSocket :: N.AddrInfo -> IO N.Socket
    createSocket addr = mapIOException insufficientResources $
      N.socket (N.addrFamily addr) N.Stream N.defaultProtocol

    invalidAddress        = TransportError ConnectNotFound . show
    insufficientResources = TransportError ConnectInsufficientResources . show
    failed                = TransportError ConnectFailed . show
    timeoutError          = TransportError ConnectTimeout "Timed out"

-- | Encode end point address
encodeEndPointAddress :: N.HostName
                      -> N.ServiceName
                      -> EndPointId
                      -> EndPointAddress
encodeEndPointAddress host port ix = EndPointAddress . BSC.pack $
  host ++ ":" ++ port ++ ":" ++ show ix

-- | Decode end point address
decodeEndPointAddress :: EndPointAddress
                      -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) =
  case splitMaxFromEnd (== ':') 2 $ BSC.unpack bs of
    [host, port, endPointIdStr] ->
      case reads endPointIdStr of
        [(endPointId, "")] -> Just (host, port, endPointId)
        _                  -> Nothing
    _ ->
      Nothing

-- | Construct a ConnectionId
createConnectionId :: HeavyweightConnectionId
                   -> LightweightConnectionId
                   -> ConnectionId
createConnectionId hcid lcid =
  (fromIntegral hcid `shiftL` 32) .|. fromIntegral lcid

-- | @spltiMaxFromEnd p n xs@ splits list @xs@ at elements matching @p@,
-- returning at most @p@ segments -- counting from the /end/
--
-- > splitMaxFromEnd (== ':') 2 "ab:cd:ef:gh" == ["ab:cd", "ef", "gh"]
splitMaxFromEnd :: (a -> Bool) -> Int -> [a] -> [[a]]
splitMaxFromEnd p = \n -> go [[]] n . reverse
  where
    -- go :: [[a]] -> Int -> [a] -> [[a]]
    go accs         _ []     = accs
    go ([]  : accs) 0 xs     = reverse xs : accs
    go (acc : accs) n (x:xs) =
      if p x then go ([] : acc : accs) (n - 1) xs
             else go ((x : acc) : accs) n xs
    go _ _ _ = error "Bug in splitMaxFromEnd"

--------------------------------------------------------------------------------
-- Functions from TransportInternals                                          --
--------------------------------------------------------------------------------

-- Find a socket between two endpoints
--
-- Throws an IO exception if the socket could not be found.
internalSocketBetween :: TCPTransport    -- ^ Transport
                      -> EndPointAddress -- ^ Local endpoint
                      -> EndPointAddress -- ^ Remote endpoint
                      -> IO N.Socket
internalSocketBetween transport ourAddress theirAddress = do
  ourEndPoint <- withMVar (transportState transport) $ \st -> case st of
      TransportClosed ->
        throwIO $ userError "Transport closed"
      TransportValid vst ->
        case vst ^. localEndPointAt ourAddress of
          Nothing -> throwIO $ userError "Local endpoint not found"
          Just ep -> return ep
  theirEndPoint <- withMVar (localState ourEndPoint) $ \st -> case st of
      LocalEndPointClosed ->
        throwIO $ userError "Local endpoint closed"
      LocalEndPointValid vst ->
        case vst ^. localConnectionTo theirAddress of
          Nothing -> throwIO $ userError "Remote endpoint not found"
          Just ep -> return ep
  withMVar (remoteState theirEndPoint) $ \st -> case st of
    RemoteEndPointInit _ _ _ ->
      throwIO $ userError "Remote endpoint not yet initialized"
    RemoteEndPointValid vst ->
      return $ remoteSocket vst
    RemoteEndPointClosing _ vst ->
      return $ remoteSocket vst
    RemoteEndPointClosed ->
      throwIO $ userError "Remote endpoint closed"
    RemoteEndPointInvalid err ->
      throwIO err
    RemoteEndPointFailed err ->
      throwIO err

--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

-- | We reserve a bunch of connection IDs for control messages
firstNonReservedLightweightConnectionId :: LightweightConnectionId
firstNonReservedLightweightConnectionId = 1024

-- | Self-connection
heavyweightSelfConnectionId :: HeavyweightConnectionId
heavyweightSelfConnectionId = 0

-- | We reserve some connection IDs for special heavyweight connections
firstNonReservedHeavyweightConnectionId :: HeavyweightConnectionId
firstNonReservedHeavyweightConnectionId = 1

--------------------------------------------------------------------------------
-- Accessor definitions                                                       --
--------------------------------------------------------------------------------

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\es st -> st { _localEndPoints = es })

nextEndPointId :: Accessor ValidTransportState EndPointId
nextEndPointId = accessor _nextEndPointId (\eid st -> st { _nextEndPointId = eid })

localNextConnOutId :: Accessor ValidLocalEndPointState LightweightConnectionId
localNextConnOutId = accessor _localNextConnOutId (\cix st -> st { _localNextConnOutId = cix })

localConnections :: Accessor ValidLocalEndPointState (Map EndPointAddress RemoteEndPoint)
localConnections = accessor _localConnections (\es st -> st { _localConnections = es })

nextConnInId :: Accessor ValidLocalEndPointState HeavyweightConnectionId
nextConnInId = accessor _nextConnInId (\rid st -> st { _nextConnInId = rid })

remoteOutgoing :: Accessor ValidRemoteEndPointState Int
remoteOutgoing = accessor _remoteOutgoing (\cs conn -> conn { _remoteOutgoing = cs })

remoteIncoming :: Accessor ValidRemoteEndPointState (Set LightweightConnectionId)
remoteIncoming = accessor _remoteIncoming (\cs conn -> conn { _remoteIncoming = cs })

remoteMaxIncoming :: Accessor ValidRemoteEndPointState LightweightConnectionId
remoteMaxIncoming = accessor _remoteMaxIncoming (\lcid st -> st { _remoteMaxIncoming = lcid })

remoteNextConnOutId :: Accessor ValidRemoteEndPointState LightweightConnectionId
remoteNextConnOutId = accessor _remoteNextConnOutId (\cix st -> st { _remoteNextConnOutId = cix })

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr

localConnectionTo :: EndPointAddress -> Accessor ValidLocalEndPointState (Maybe RemoteEndPoint)
localConnectionTo addr = localConnections >>> DAC.mapMaybe addr

-------------------------------------------------------------------------------
-- Debugging                                                                 --
-------------------------------------------------------------------------------

relyViolation :: EndPointPair -> String -> IO a
relyViolation (ourEndPoint, theirEndPoint) str = do
  elog (ourEndPoint, theirEndPoint) (str ++ " RELY violation")
  fail (str ++ " RELY violation")

elog :: EndPointPair -> String -> IO ()
elog (ourEndPoint, theirEndPoint) msg = do
  tid <- myThreadId
  putStrLn  $  show (localAddress ourEndPoint)
    ++ "/"  ++ show (remoteAddress theirEndPoint)
    ++ "("  ++ show (remoteId theirEndPoint) ++ ")"
    ++ "/"  ++ show tid
    ++ ": " ++ msg
