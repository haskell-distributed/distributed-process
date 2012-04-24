-- | TCP transport
--
-- TODOs:
-- * Various errors are still left as "undefined"
-- * Many possible errors are not yet dealt with
-- * Connections are not yet lightweight
module Network.Transport.TCP ( -- * Main API
                               createTransport
                             , -- TCP specific functionality
                               EndPointId
                             , decodeEndPointAddress
                             ) where

import Network.Transport
import Network.Transport.Internal.TCP ( forkServer
                                      , connectTo
                                      , recvExact 
                                      , recvWithLength
                                      , sendWithLength
                                      , recvInt16
                                      , recvInt32
                                      , sendInt32
                                      )
import Network.Transport.Internal ( encodeInt16 
                                  , failWith
                                  , failWithT
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , sClose
                                     , accept
                                     )
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, readMVar)
import Control.Category ((>>>))
import Control.Applicative ((<*>), (*>), (<$>))
import Control.Monad (forever, forM_)
import Control.Monad.Error (ErrorT, liftIO, runErrorT)
import Control.Monad.Trans.Maybe (MaybeT(MaybeT), runMaybeT)
import Control.Monad.Trans.Writer (WriterT, execWriterT)
import Control.Monad.Writer.Class (tell)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Data.Int (Int16)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty, size)
import Data.Lens.Lazy (Lens, lens, intMapLens, (^.), (^=), (^+=))
import Text.Regex.Applicative (RE, few, anySym, sym, many, match)

data TransportState = TransportState { _endPoints        :: IntMap (Chan Event, MVar EndPointState) }
data EndPointState  = EndPointState  { _nextConnectionId :: ConnectionId }
type EndPointId     = Int16

endPoints :: Lens TransportState (IntMap (Chan Event, MVar EndPointState))
endPoints = lens _endPoints (\es st -> st { _endPoints = es })

nextConnectionId :: Lens EndPointState ConnectionId
nextConnectionId = lens _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

endPointAt :: EndPointId -> Lens TransportState (Maybe (Chan Event, MVar EndPointState))
endPointAt ix = endPoints >>> intMapLens (fromIntegral ix)

-- | Create a TCP transport
--
-- Hostname and service name should be "canonical" for the transport layer to
-- use TCP channels bidirectionally (otherwise when A connects to B and B
-- connects to A two socket pairs will be created that will both be used
-- unidirectionally, at degraded performance). 
--
-- TODOs:
-- * Perhaps we should allow to use something different other than 'defaultHints'
-- * Deal with all exceptions that may occur
createTransport :: N.HostName -> N.ServiceName -> IO Transport
createTransport host port = do 
  state <- newMVar TransportState { _endPoints = IntMap.empty }
  forkServer host port (transportServer state)
  return Transport { newEndPoint = tcpNewEndPoint state host port } 

-- | The transport server handles incoming connections for all endpoints
--
-- TODO: lots of error checking
transportServer :: MVar TransportState -> N.Socket -> IO ()
transportServer state sock = forever $ do
  (clientSock, _) <- N.accept sock
  forkIO $ handleClient state clientSock >> N.sClose clientSock
    
-- | Handle a new incoming connection
--
-- Returns when the client closes the socket and on invalid input.
handleClient :: MVar TransportState -> N.Socket -> IO () 
handleClient state sock = do 
  mendpoint <- runMaybeT $ do 
    ourEndPointId <- recvInt16 sock
    theirAddress  <- BS.concat <$> recvWithLength sock 
    ourEndPoint   <- MaybeT $ (^. endPointAt ourEndPointId) <$> readMVar state   
    return (ourEndPoint, EndPointAddress theirAddress)
  case mendpoint of
    Just ((endPointCh, endPointSt), theirAddress) -> do
      unclosedConnections <- endpointServer sock theirAddress endPointCh endPointSt
      forM_ unclosedConnections $ \cix -> writeChan endPointCh (ConnectionClosed cix)
    Nothing ->
      -- Invalid request
      return () 

-- | Handle requests for one endpoint. Returns only if an error occurs,
-- in which case it returns the connections that are still open (normally,
-- this should be an empty list).
endpointServer :: N.Socket -> EndPointAddress -> Chan Event -> MVar EndPointState -> IO [ConnectionId] 
endpointServer sock theirAddress chan state = execWriterT . runMaybeT . forever $ do
    connId <- recvInt32 sock
    case connId of
      0 -> createNewConnection
      _ -> readMessage connId
  where
    -- A brief note on the types:
    -- These functions may fail (connection error): hence MaybeT
    -- We also need to keep track of which connections are still open: hence WriterT

    -- Create a new connection
    createNewConnection :: MaybeT (WriterT [ConnectionId] IO) () 
    createNewConnection = do
      newId <- liftIO $ modifyMVar state $ \st -> return (nextConnectionId ^+= 1 $ st, st ^. nextConnectionId)  
      sendInt32 sock newId
      liftIO $ writeChan chan (ConnectionOpened newId ReliableOrdered theirAddress) 
      -- We add the new connection ID to the list of open connections only once the
      -- endpoint has been notified of the new connection (sendInt32 may fail)
      tell [newId]
    
    -- Read a message and output it on the endPoint's channel
    readMessage :: ConnectionId -> MaybeT (WriterT [ConnectionId] IO) ()
    readMessage connId = recvWithLength sock >>= liftIO . writeChan chan . Received connId

-- | Create a new endpoint
tcpNewEndPoint :: MVar TransportState -> N.HostName -> N.ServiceName -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
tcpNewEndPoint transportState host port = do 
  chan          <- newChan
  endPointState <- newMVar EndPointState { _nextConnectionId = firstNonReservedConnectionId }
  endPointId    <- modifyMVar transportState $ \st -> do let ix = fromIntegral $ IntMap.size (st ^. endPoints) 
                                                         return ((endPointAt ix ^= Just (chan, endPointState)) $ st, ix)
  let addr = EndPointAddress . BSC.pack $ host ++ ":" ++ port ++ ":" ++ show endPointId
  return . Right $ EndPoint { receive = readChan chan  
                            , address = addr 
                            , connect = tcpConnect addr 
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
tcpConnect :: EndPointAddress -> EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
tcpConnect myAddress theirAddress _ = runErrorT $ do
  sock   <- socketForEndPoint myAddress theirAddress 
  connId <- failWithT undefined $ requestNewConnection sock
  return Connection { send  = runErrorT . 
                              failWithT (FailedWith SendFailed "Send failed") . 
                              sendWithLength sock (Just connId) 
                    , close = N.sClose sock 
                    }

-- | Request a new connection 
-- Returns the new connection ID in serialized form
requestNewConnection :: N.Socket -> MaybeT IO ByteString 
requestNewConnection sock = sendInt32 sock 0 >> BS.concat <$> recvExact sock 4

-- | Find a socket to the specified endpoint
--
-- TODOs:
-- * Reuse connections
-- * Hints?
socketForEndPoint :: EndPointAddress -- ^ Our address 
                  -> EndPointAddress -- ^ Their address
                  -> ErrorT (FailedWith ConnectErrorCode) IO N.Socket
socketForEndPoint (EndPointAddress myAddress) theirAddress = do
    (host, port, endPointId) <- failWith invalidAddress (decodeEndPointAddress theirAddress)
    sock <- failWithT undefined (connectTo host port)
    endPointBS <- encodeInt16 endPointId 
    failWithT undefined $ sendWithLength sock (Just endPointBS) [myAddress]
    return sock 
  where
    invalidAddress = FailedWith ConnectInvalidAddress "Invalid address"

-- | Decode end point address
-- TODO: This uses regular expression parsing, which is nice, but unnecessary
decodeEndPointAddress :: EndPointAddress -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) = match endPointAddressRE (BSC.unpack bs) 
  where
    endPointAddressRE :: RE Char (N.HostName, N.ServiceName, EndPointId)
    endPointAddressRE = (,,) <$> few anySym <*> (sym ':' *> few anySym) <*> (sym ':' *> (read <$> many anySym))
