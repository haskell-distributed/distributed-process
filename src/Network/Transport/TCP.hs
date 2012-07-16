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
module Network.Transport.TCP ( -- * Main API
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
                             , firstNonReservedConnectionId
                             , socketToEndPoint 
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
import Network.Transport.TCP.Internal ( forkServer
                                      , recvWithLength
                                      , recvInt32
                                      , tryCloseSocket
                                      )
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
                                  , prependLength
                                  , mapIOException
                                  , tryIO
                                  , tryToEnum
                                  , void
                                  , timeoutMaybe
                                  , asyncWhenCancelled
                                  )
import qualified Network.Socket as N ( HostName
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
import Control.Monad (when, unless)
import Control.Exception ( IOException
                         , SomeException
                         , AsyncException
                         , handle
                         , throw
                         , throwIO
                         , try
                         , bracketOnError
                         , mask
                         , onException
                         , fromException
                         )
import Data.IORef (IORef, newIORef, writeIORef, readIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack, split)
import Data.Int (Int32)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet ( empty
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
import qualified Data.Accessor.Container as DAC (mapMaybe, intMapMaybe)
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
  { transportHost   :: N.HostName
  , transportPort   :: N.ServiceName
  , transportState  :: MVar TransportState 
  , transportParams :: TCPParameters
  }

data TransportState = 
    TransportValid ValidTransportState
  | TransportClosed

data ValidTransportState = ValidTransportState 
  { _localEndPoints :: Map EndPointAddress LocalEndPoint 
  , _nextEndPointId :: EndPointId 
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
  { _nextConnectionId :: !ConnectionId 
  , _localConnections :: Map EndPointAddress RemoteEndPoint 
  , _nextRemoteId     :: !Int
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
--   requestConnectionTo (in response to an API 'connect' call) and in
--   handleConnectionRequest (when a remote node tries to connect to us).
--   'Init' carries an MVar () 'resolved' which concurrent threads can use to
--   wait for the remote endpoint to finish initialization. We record who
--   requested the connection (the local endpoint or the remote endpoint).
--
-- Invalid: We put the remote endpoint in invalid state only during
--   requestConnectionTo when we fail to connect.
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
  { remoteAddress :: EndPointAddress
  , remoteState   :: MVar RemoteState
  , remoteId      :: Int
  }

data RequestedBy = RequestedByUs | RequestedByThem 
  deriving (Eq, Show)

data RemoteState =
    -- | Invalid remote endpoint (for example, invalid address)
    RemoteEndPointInvalid (TransportError ConnectErrorCode)
    -- | The remote endpoint is being initialized
  | RemoteEndPointInit (MVar ()) RequestedBy 
    -- | "Normal" working endpoint
  | RemoteEndPointValid ValidRemoteEndPointState 
    -- | The remote endpoint is being closed (garbage collected)
  | RemoteEndPointClosing (MVar ()) ValidRemoteEndPointState
    -- | The remote endpoint has been closed (garbage collected)
  | RemoteEndPointClosed
    -- | The remote endpoint has failed, or has been forcefully shutdown
    -- using a closeTransport or closeEndPoint API call
  | RemoteEndPointFailed IOException

data ValidRemoteEndPointState = ValidRemoteEndPointState 
  { _remoteOutgoing      :: !Int
  , _remoteIncoming      :: IntSet
  ,  remoteSocket        :: N.Socket
  ,  sendOn              :: [ByteString] -> IO ()
  , _pendingCtrlRequests :: IntMap (MVar (Either IOException [ByteString]))
  , _nextCtrlRequestId   :: !ControlRequestId 
  }

-- | Local identifier for an endpoint within this transport
type EndPointId       = Int32

-- | Control request ID
-- 
-- Control requests are asynchronous; the request ID makes it possible to match
-- requests and replies
type ControlRequestId = Int32

-- | Pair of local and a remote endpoint (for conciseness in signatures)
type EndPointPair     = (LocalEndPoint, RemoteEndPoint)

-- | Control headers 
data ControlHeader = 
    -- | Request a new connection ID from the remote endpoint
    RequestConnectionId 
    -- | Tell the remote endpoint we will no longer be using a connection
  | CloseConnection     
    -- | Respond to a control request /from/ the remote endpoint
  | ControlResponse     
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
          requestConnectionTo params ourEndPoint theirAddress hints
        -- connAlive can be an IORef rather than an MVar because it is protected
        -- by the remoteState MVar. We don't need the overhead of locking twice.
        connAlive <- newIORef True
        return Connection 
          { send  = apiSend  (ourEndPoint, theirEndPoint) connId connAlive 
          , close = apiClose (ourEndPoint, theirEndPoint) connId connAlive 
          }

-- | Close a connection
apiClose :: EndPointPair -> ConnectionId -> IORef Bool -> IO ()
apiClose (ourEndPoint, theirEndPoint) connId connAlive = 
  void . tryIO . asyncWhenCancelled return $ do 
    modifyRemoteState_ (ourEndPoint, theirEndPoint) remoteStateIdentity  
      { caseValid = \vst -> do
          alive <- readIORef connAlive
          if alive 
            then do
              writeIORef connAlive False
              sendOn vst [encodeInt32 CloseConnection, encodeInt32 connId] 
              return ( RemoteEndPointValid 
                     . (remoteOutgoing ^: (\x -> x - 1)) 
                     $ vst
                     )
            else
              return (RemoteEndPointValid vst)
      }
    closeIfUnused (ourEndPoint, theirEndPoint)

-- | Send data across a connection
apiSend :: EndPointPair  -- ^ Local and remote endpoint 
        -> ConnectionId  -- ^ Connection ID (supplied by remote endpoint)
        -> IORef Bool    -- ^ Is the connection still alive?
        -> [ByteString]  -- ^ Payload
        -> IO (Either (TransportError SendErrorCode) ())
apiSend (ourEndPoint, theirEndPoint) connId connAlive payload =  
    -- We don't need the overhead of asyncWhenCancelled here
    try . mapIOException sendFailed $ 
      withRemoteState (ourEndPoint, theirEndPoint) RemoteStatePatternMatch
        { caseInvalid = \_ -> 
            relyViolation (ourEndPoint, theirEndPoint) "apiSend"
        , caseInit = \_ _ ->
            relyViolation (ourEndPoint, theirEndPoint) "apiSend"
        , caseValid = \vst -> do
            alive <- readIORef connAlive
            if alive 
              then sendOn vst (encodeInt32 connId : prependLength payload)
              else throwIO $ TransportError SendClosed "Connection closed"
        , caseClosing = \_ _ -> do
            alive <- readIORef connAlive
            if alive 
              then relyViolation (ourEndPoint, theirEndPoint) "apiSend" 
              else throwIO $ TransportError SendClosed "Connection closed"
        , caseClosed = do
            alive <- readIORef connAlive
            if alive 
              then relyViolation (ourEndPoint, theirEndPoint) "apiSend" 
              else throwIO $ TransportError SendClosed "Connection closed"
        , caseFailed = \err -> do
            alive <- readIORef connAlive
            if alive 
              then throwIO $ TransportError SendFailed (show err) 
              else throwIO $ TransportError SendClosed "Connection closed"
        }
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
      modifyMVar_ (remoteState theirEndPoint) $ \st ->
        case st of
          RemoteEndPointInvalid _ -> 
            return st
          RemoteEndPointInit resolved _ -> do
            putMVar resolved ()
            return closed 
          RemoteEndPointValid conn -> do 
            tryIO $ sendOn conn [encodeInt32 CloseSocket]
            tryCloseSocket (remoteSocket conn)
            return closed 
          RemoteEndPointClosing resolved conn -> do 
            putMVar resolved ()
            tryCloseSocket (remoteSocket conn)
            return closed 
          RemoteEndPointClosed ->
            return st
          RemoteEndPointFailed err ->
            return $ RemoteEndPointFailed err 

--------------------------------------------------------------------------------
-- As soon as a remote connection fails, we want to put notify our endpoint   --
-- and put it into a closed state. Since this may happen in many places, we   --
-- provide some abstractions.                                                 --
--------------------------------------------------------------------------------

data RemoteStatePatternMatch a = RemoteStatePatternMatch 
  { caseInvalid :: TransportError ConnectErrorCode -> IO a
  , caseInit    :: MVar () -> RequestedBy -> IO a
  , caseValid   :: ValidRemoteEndPointState -> IO a
  , caseClosing :: MVar () -> ValidRemoteEndPointState -> IO a
  , caseClosed  :: IO a
  , caseFailed  :: IOException -> IO a
  }

remoteStateIdentity :: RemoteStatePatternMatch RemoteState
remoteStateIdentity =
  RemoteStatePatternMatch 
    { caseInvalid = return . RemoteEndPointInvalid
    , caseInit    = (return .) . RemoteEndPointInit
    , caseValid   = return . RemoteEndPointValid
    , caseClosing = (return .) . RemoteEndPointClosing 
    , caseClosed  = return RemoteEndPointClosed
    , caseFailed  = return . RemoteEndPointFailed
    }

-- | Like modifyMVar, but if an I/O exception occurs don't restore the remote
-- endpoint to its original value but close it instead 
modifyRemoteState :: EndPointPair 
                  -> RemoteStatePatternMatch (RemoteState, a) 
                  -> IO a
modifyRemoteState (ourEndPoint, theirEndPoint) match = 
    mask $ \restore -> do
      st <- takeMVar theirState
      case st of
        RemoteEndPointValid vst -> do
          mResult <- try $ restore (caseValid match vst) 
          case mResult of
            Right (st', a) -> do
              putMVar theirState st'
              return a
            Left ex -> do
              case fromException ex of
                Just ioEx -> handleIOException ioEx vst 
                Nothing   -> putMVar theirState st 
              throwIO ex
        -- The other cases are less interesting, because unless the endpoint is
        -- in Valid state we're not supposed to do any IO on it
        RemoteEndPointInit resolved origin -> do
          (st', a) <- onException (restore $ caseInit match resolved origin)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointClosing resolved vst -> do 
          (st', a) <- onException (restore $ caseClosing match resolved vst)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointInvalid err -> do
          (st', a) <- onException (restore $ caseInvalid match err)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointClosed -> do
          (st', a) <- onException (restore $ caseClosed match)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointFailed err -> do
          (st', a) <- onException (restore $ caseFailed match err)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
  where
    theirState :: MVar RemoteState
    theirState = remoteState theirEndPoint

    handleIOException :: IOException -> ValidRemoteEndPointState -> IO () 
    handleIOException ex vst = do
      tryCloseSocket (remoteSocket vst)
      putMVar theirState (RemoteEndPointFailed ex)
      let incoming = IntSet.elems $ vst ^. remoteIncoming
          code     = EventConnectionLost (Just $ remoteAddress theirEndPoint) incoming
          err      = TransportError code (show ex)
      writeChan (localChannel ourEndPoint) $ ErrorEvent err 

-- | Like 'modifyRemoteState' but without a return value
modifyRemoteState_ :: EndPointPair
                   -> RemoteStatePatternMatch RemoteState 
                   -> IO ()
modifyRemoteState_ (ourEndPoint, theirEndPoint) match =
    modifyRemoteState (ourEndPoint, theirEndPoint) 
      RemoteStatePatternMatch 
        { caseInvalid = u . caseInvalid match
        , caseInit    = \resolved origin -> u $ caseInit match resolved origin
        , caseValid   = u . caseValid match
        , caseClosing = \resolved vst -> u $ caseClosing match resolved vst
        , caseClosed  = u $ caseClosed match
        , caseFailed  = u . caseFailed match
        }
  where
    u :: IO a -> IO (a, ())
    u p = p >>= \a -> return (a, ())

-- | Like 'modifyRemoteState' but without the ability to change the state
withRemoteState :: EndPointPair
                -> RemoteStatePatternMatch a
                -> IO a 
withRemoteState (ourEndPoint, theirEndPoint) match =
  modifyRemoteState (ourEndPoint, theirEndPoint)
    RemoteStatePatternMatch 
      { caseInvalid = \err -> do
          a <- caseInvalid match err
          return (RemoteEndPointInvalid err, a)
      , caseInit = \resolved origin -> do
          a <- caseInit match resolved origin
          return (RemoteEndPointInit resolved origin, a)
      , caseValid = \vst -> do
          a <- caseValid match vst
          return (RemoteEndPointValid vst, a)
      , caseClosing = \resolved vst -> do 
          a <- caseClosing match resolved vst
          return (RemoteEndPointClosing resolved vst, a)
      , caseClosed = do 
          a <- caseClosed match
          return (RemoteEndPointClosed, a)
      , caseFailed = \err -> do 
          a <- caseFailed match err
          return (RemoteEndPointFailed err, a)
      }

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
            let vst = ValidRemoteEndPointState 
                        {  remoteSocket        = sock
                        , _remoteOutgoing      = 0
                        , _remoteIncoming      = IntSet.empty
                        , sendOn               = sendMany sock
                        , _pendingCtrlRequests = IntMap.empty
                        , _nextCtrlRequestId   = 0
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
        RemoteEndPointInit _ _ ->
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
      connId <- recvInt32 sock 
      if connId >= firstNonReservedConnectionId 
        then do
          readMessage sock connId
          go sock
        else 
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
              throwIO $ userError "Invalid control request"
        
    -- Create a new connection
    createNewConnection :: ControlRequestId -> IO () 
    createNewConnection reqId = do 
      newId <- getNextConnectionId ourEndPoint
      modifyMVar_ theirState $ \st -> do
        vst <- case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "handleIncomingMessages:createNewConnection (invalid)"
          RemoteEndPointInit _ _ ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "handleIncomingMessages:createNewConnection (init)"
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
          RemoteEndPointFailed err -> 
            throwIO err
          RemoteEndPointClosed ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "createNewConnection (closed)"
        sendOn vst ( encodeInt32 ControlResponse 
                   : encodeInt32 reqId 
                   : prependLength [encodeInt32 newId] 
                   )
        return (RemoteEndPointValid vst)
      writeChan ourChannel (ConnectionOpened newId ReliableOrdered theirAddr) 

    -- Read a control response 
    readControlResponse :: N.Socket -> ControlRequestId -> IO () 
    readControlResponse sock reqId = do
      response <- recvWithLength sock
      mmvar    <- modifyMVar theirState $ \st -> case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint)
            "readControlResponse (invalid)"
        RemoteEndPointInit _ _ ->
          relyViolation (ourEndPoint, theirEndPoint)
            "readControlResponse (init)"
        RemoteEndPointValid vst ->
          return ( RemoteEndPointValid 
                 . (pendingCtrlRequestsAt reqId ^= Nothing) 
                 $ vst
                 , vst ^. pendingCtrlRequestsAt reqId
                 )
        RemoteEndPointClosing _ _ ->
          throwIO $ userError "Invalid control response"
        RemoteEndPointFailed err ->
          throwIO err
        RemoteEndPointClosed ->
          relyViolation (ourEndPoint, theirEndPoint) 
            "readControlResponse (closed)"
      case mmvar of
        Nothing -> 
          throwIO $ userError "Invalid request ID"
        Just mvar -> 
          putMVar mvar (Right response)

    -- Close a connection 
    -- It is important that we verify that the connection is in fact open,
    -- because otherwise we should not decrement the reference count
    closeConnection :: ConnectionId -> IO () 
    closeConnection cid = do
      modifyMVar_ theirState $ \st -> case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection (invalid)"
        RemoteEndPointInit _ _ ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection (init)"
        RemoteEndPointValid vst -> do 
          unless (IntSet.member cid (vst ^. remoteIncoming)) $ 
            throwIO $ userError "Invalid CloseConnection"
          return ( RemoteEndPointValid 
                 . (remoteIncoming ^: IntSet.delete cid) 
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
      writeChan ourChannel (ConnectionClosed cid)
      closeIfUnused (ourEndPoint, theirEndPoint)

    -- Close the socket (if we don't have any outgoing connections)
    closeSocket :: N.Socket -> IO Bool 
    closeSocket sock =
      modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint)
              "handleIncomingMessages:closeSocket (invalid)"
          RemoteEndPointInit _ _ ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "handleIncomingMessages:closeSocket (init)"
          RemoteEndPointValid vst -> do
            -- We regard a CloseSocket message as an (optimized) way for the
            -- remote endpoint to indicate that all its connections to us are
            -- now properly closed
            forM_ (IntSet.elems $ vst ^. remoteIncoming) $ 
              writeChan ourChannel . ConnectionClosed 
            let vst' = remoteIncoming ^= IntSet.empty $ vst 
            -- Check if we agree that the connection should be closed
            if vst' ^. remoteOutgoing == 0 
              then do 
                removeRemoteEndPoint (ourEndPoint, theirEndPoint)
                -- Attempt to reply (but don't insist)
                tryIO $ sendOn vst' [encodeInt32 CloseSocket]
                tryCloseSocket sock 
                return (RemoteEndPointClosed, True)
              else 
                return (RemoteEndPointValid vst', False)
          RemoteEndPointClosing resolved  _ -> do
            removeRemoteEndPoint (ourEndPoint, theirEndPoint)
            tryCloseSocket sock 
            putMVar resolved ()
            return (RemoteEndPointClosed, True)
          RemoteEndPointFailed err ->
            throwIO err
          RemoteEndPointClosed ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "handleIncomingMessages:closeSocket (closed)"
            
    -- Read a message and output it on the endPoint's channel. By rights we
    -- should verify that the connection ID is valid, but this is unnecessary
    -- overhead
    readMessage :: N.Socket -> ConnectionId -> IO () 
    readMessage sock connId = 
      recvWithLength sock >>= writeChan ourChannel . Received connId

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
          RemoteEndPointInit _ _ ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "handleIncomingMessages:prematureExit"
          RemoteEndPointValid vst -> do
            let code = EventConnectionLost 
                         (Just $ remoteAddress theirEndPoint) 
                         (IntSet.elems $ vst ^. remoteIncoming)
            writeChan ourChannel . ErrorEvent $ TransportError code (show err)
            forM_ (vst ^. pendingCtrlRequests) $ flip putMVar (Left err) 
            return (RemoteEndPointFailed err)
          RemoteEndPointClosing resolved _ -> do
            putMVar resolved ()
            return (RemoteEndPointFailed err)
          RemoteEndPointClosed ->
            relyViolation (ourEndPoint, theirEndPoint) 
              "handleIncomingMessages:prematureExit"
          RemoteEndPointFailed err' ->
            return (RemoteEndPointFailed err')

--------------------------------------------------------------------------------
-- Uninterruptable auxiliary functions                                        --
--                                                                            --
-- All these functions assume they are running in a thread which will never   --
-- be killed.
--------------------------------------------------------------------------------

-- | Request a connection to a remote endpoint
--
-- This will block until we get a connection ID from the remote endpoint; if
-- the remote endpoint was in 'RemoteEndPointClosing' state then we will
-- additionally block until that is resolved. 
--
-- May throw a TransportError ConnectErrorCode exception.
requestConnectionTo :: TCPParameters 
                    -> LocalEndPoint 
                    -> EndPointAddress 
                    -> ConnectHints
                    -> IO (RemoteEndPoint, ConnectionId)
requestConnectionTo params ourEndPoint theirAddress hints = go
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
          reply <- mapIOException connectFailed $ 
            doRemoteRequest (ourEndPoint, theirEndPoint) RequestConnectionId 
          return (theirEndPoint, decodeInt32 . BS.concat $ reply)

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
        let vst = ValidRemoteEndPointState 
                    {  remoteSocket        = sock
                    , _remoteOutgoing      = 0 
                    , _remoteIncoming      = IntSet.empty
                    ,  sendOn              = sendMany sock 
                    , _pendingCtrlRequests = IntMap.empty
                    , _nextCtrlRequestId   = 0
                    }
        resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointValid vst)
        return True
      Right (sock, ConnectionRequestInvalid) -> do
        let err = invalidAddress "setupRemoteEndPoint: Invalid endpoint"
        resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointInvalid err)
        tryCloseSocket sock
        return False
      Right (sock, ConnectionRequestCrossed) -> do
        resolveInit (ourEndPoint, theirEndPoint) RemoteEndPointClosed
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

-- | Do a (blocking) remote request 
-- 
-- May throw IO (user) exception if the local or the remote endpoint is closed,
-- if the send fails, or if the remote endpoint fails before it replies.
doRemoteRequest :: EndPointPair -> ControlHeader -> IO [ByteString]
doRemoteRequest (ourEndPoint, theirEndPoint) header = do 
  replyMVar <- newEmptyMVar
  modifyRemoteState_ (ourEndPoint, theirEndPoint) RemoteStatePatternMatch 
    { caseValid = \vst -> do 
        let reqId = vst ^. nextCtrlRequestId
        sendOn vst [encodeInt32 header, encodeInt32 reqId]
        return ( RemoteEndPointValid
               . (nextCtrlRequestId ^: (+ 1))
               . (pendingCtrlRequestsAt reqId ^= Just replyMVar)
               $ vst
               ) 
    -- Error cases
    , caseInvalid = 
        throwIO 
    , caseInit = \_ _ -> 
        relyViolation (ourEndPoint, theirEndPoint) "doRemoteRequest (init)"
    , caseClosing = \_ _ -> 
        relyViolation (ourEndPoint, theirEndPoint) "doRemoteRequest (closing)" 
    , caseClosed =
        relyViolation (ourEndPoint, theirEndPoint) "doRemoteRequest (closed)" 
    , caseFailed =
        throwIO
    }
  mReply <- takeMVar replyMVar
  case mReply of
    Left err    -> throwIO err
    Right reply -> return reply

-- | Send a CloseSocket request if the remote endpoint is unused
closeIfUnused :: EndPointPair -> IO ()
closeIfUnused (ourEndPoint, theirEndPoint) =
  modifyRemoteState_ (ourEndPoint, theirEndPoint) remoteStateIdentity 
    { caseValid = \vst -> 
        if vst ^. remoteOutgoing == 0 && IntSet.null (vst ^. remoteIncoming) 
          then do 
            sendOn vst [encodeInt32 CloseSocket]
            resolved <- newEmptyMVar
            return $ RemoteEndPointClosing resolved vst 
          else 
            return $ RemoteEndPointValid vst
    }

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
    connId    <- mapIOException connectFailed $ getNextConnectionId ourEndPoint 
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
    RemoteEndPointInit resolved _ -> do
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

-- | Get the next connection ID
-- 
-- Throws an IO exception when the endpoint is closed.
getNextConnectionId :: LocalEndPoint -> IO ConnectionId
getNextConnectionId ourEndpoint = 
  modifyMVar (localState ourEndpoint) $ \st -> case st of
    LocalEndPointValid vst -> do
      let connId = vst ^. nextConnectionId 
      return ( LocalEndPointValid 
             . (nextConnectionId ^= connId + 1) 
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
      { _nextConnectionId    = firstNonReservedConnectionId 
      , _localConnections    = Map.empty
      , _nextRemoteId        = 0
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
            resolved <- newEmptyMVar
            theirState <- newMVar (RemoteEndPointInit resolved findOrigin)
            let theirEndPoint = RemoteEndPoint
                                  { remoteAddress = theirAddress
                                  , remoteState   = theirState
                                  , remoteId      = vst ^. nextRemoteId
                                  }
            return ( LocalEndPointValid 
                   . (localConnectionTo theirAddress ^= Just theirEndPoint) 
                   . (nextRemoteId ^: (+ 1)) 
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
            RemoteEndPointInit resolved initOrigin ->
              case (findOrigin, initOrigin) of
                (RequestedByUs, RequestedByUs) -> 
                  readMVar resolved >> go 
                (RequestedByUs, RequestedByThem) -> 
                  readMVar resolved >> go
                (RequestedByThem, RequestedByUs) -> 
                  if ourAddress > theirAddress 
                    then
                      -- Wait for the Crossed message
                      readMVar resolved >> go 
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
  case map BSC.unpack $ BSC.split ':' bs of
    [host, port, endPointIdStr] -> 
      case reads endPointIdStr of 
        [(endPointId, "")] -> Just (host, port, endPointId)
        _                  -> Nothing
    _ ->
      Nothing

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
    RemoteEndPointInit _ _ ->
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
firstNonReservedConnectionId :: ConnectionId
firstNonReservedConnectionId = 1024

--------------------------------------------------------------------------------
-- Accessor definitions                                                       --
--------------------------------------------------------------------------------

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\es st -> st { _localEndPoints = es })

nextEndPointId :: Accessor ValidTransportState EndPointId
nextEndPointId = accessor _nextEndPointId (\eid st -> st { _nextEndPointId = eid })

nextConnectionId :: Accessor ValidLocalEndPointState ConnectionId
nextConnectionId = accessor _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

localConnections :: Accessor ValidLocalEndPointState (Map EndPointAddress RemoteEndPoint)
localConnections = accessor _localConnections (\es st -> st { _localConnections = es })

nextRemoteId :: Accessor ValidLocalEndPointState Int
nextRemoteId = accessor _nextRemoteId (\rid st -> st { _nextRemoteId = rid })

remoteOutgoing :: Accessor ValidRemoteEndPointState Int
remoteOutgoing = accessor _remoteOutgoing (\cs conn -> conn { _remoteOutgoing = cs })

remoteIncoming :: Accessor ValidRemoteEndPointState IntSet
remoteIncoming = accessor _remoteIncoming (\cs conn -> conn { _remoteIncoming = cs })

pendingCtrlRequests :: Accessor ValidRemoteEndPointState (IntMap (MVar (Either IOException [ByteString])))
pendingCtrlRequests = accessor _pendingCtrlRequests (\rep st -> st { _pendingCtrlRequests = rep })

nextCtrlRequestId :: Accessor ValidRemoteEndPointState ControlRequestId 
nextCtrlRequestId = accessor _nextCtrlRequestId (\cid st -> st { _nextCtrlRequestId = cid })

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr 

pendingCtrlRequestsAt :: ControlRequestId -> Accessor ValidRemoteEndPointState (Maybe (MVar (Either IOException [ByteString])))
pendingCtrlRequestsAt ix = pendingCtrlRequests >>> DAC.intMapMaybe (fromIntegral ix)

localConnectionTo :: EndPointAddress 
                  -> Accessor ValidLocalEndPointState (Maybe RemoteEndPoint)
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
