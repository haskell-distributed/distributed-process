-- | TCP transport
module Network.Transport.TCP ( -- * Main API
                               createTransport
                             , -- TCP specific functionality
                               EndPointIx
                             , decodeEndPointAddress
                             ) where

import Network.Transport
import Network.Transport.Internal.TCP ( forkServer
                                      , recvExact 
                                      , recvWithLength
                                      , sendWithLength
                                      )
import Network.Transport.Internal ( encodeInt16 
                                  , decodeInt16
                                  , maybeToErrorT
                                  , maybeTToErrorT
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , SocketType(Stream)
                                     , SocketOption(ReuseAddr)
                                     , getAddrInfo
                                     , socket
                                     , addrFamily
                                     , addrAddress
                                     , defaultProtocol
                                     , setSocketOption
                                     , connect
                                     , sClose
                                     , accept
                                     )
import qualified Network.Socket.ByteString as NBS (sendMany)
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, readMVar)
import Control.Category ((>>>))
import Control.Applicative ((<*>), (*>), (<$>), pure)
import Control.Monad (forever)
import Control.Monad.Error (ErrorT, liftIO, runErrorT)
import Control.Monad.Trans.Maybe (MaybeT(MaybeT), runMaybeT)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty, size)
import Data.Lens.Lazy (Lens, lens, intMapLens, (^.), (^=), (^+=))
import Text.Regex.Applicative (RE, few, anySym, sym, many, match)

data TransportState = TransportState { _endPoints        :: IntMap (Chan Event, MVar EndPointState) }
data EndPointState  = EndPointState  { _nextConnectionIx :: ConnectionIx }
type EndPointIx     = Int
type ConnectionIx   = Int

endPoints :: Lens TransportState (IntMap (Chan Event, MVar EndPointState))
endPoints = lens _endPoints (\es st -> st { _endPoints = es })

nextConnectionIx :: Lens EndPointState ConnectionIx
nextConnectionIx = lens _nextConnectionIx (\cix st -> st { _nextConnectionIx = cix })

endPointAt :: EndPointIx -> Lens TransportState (Maybe (Chan Event, MVar EndPointState))
endPointAt ix = endPoints >>> intMapLens ix

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
  state <- newMVar $ TransportState { _endPoints = IntMap.empty }
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
  runMaybeT $ do 
    -- Our endpoint the other side is interested in 
    endPointBS <- recvExact sock 2
    endPointIx <- decodeInt16 (BS.concat $ endPointBS)
    -- Full endpoint address of the other side 
    theirAddress <- BS.concat <$> recvWithLength sock 
    -- Start handling incoming messages 
    (endPointCh, endPointSt) <- MaybeT $ (^. endPointAt (fromIntegral endPointIx)) <$> readMVar state   
    endpointServer sock (EndPointAddress theirAddress) endPointCh endPointSt
  return ()

-- | Handle requests for one endpoint. Returns only if an error occurs
endpointServer :: N.Socket -> EndPointAddress -> Chan Event -> MVar EndPointState -> MaybeT IO ()
endpointServer sock theirAddress chan state = forever $ do
    connBS <- recvExact sock 2
    connIx <- fromIntegral <$> decodeInt16 (BS.concat connBS)
    if connIx == 0 
      then liftIO $ createNewConnection 
      else readMessage connIx 
  where
    -- Create a new connection
    createNewConnection :: IO () 
    createNewConnection = do
      newIx <- modifyMVar state $ \st -> return (nextConnectionIx ^+= 1 $ st, st ^. nextConnectionIx)  
      newBs <- encodeInt16 (fromIntegral newIx)
      NBS.sendMany sock [newBs]
      writeChan chan (ConnectionOpened newIx ReliableOrdered theirAddress) 
    
    -- Read a message and output it on the endPoint's channel
    readMessage :: ConnectionIx -> MaybeT IO ()
    readMessage connIx = do
      payload <- recvWithLength sock
      liftIO $ writeChan chan (Received connIx payload) 

-- | Create a new endpoint
tcpNewEndPoint :: MVar TransportState -> N.HostName -> N.ServiceName -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
tcpNewEndPoint transportState host port = do 
  chan          <- newChan
  endPointState <- newMVar $ EndPointState { _nextConnectionIx = 1 } -- Connection id 0 is reserved for requesting new connections
  endPointIx    <- modifyMVar transportState $ \st -> do let ix = IntMap.size (st ^. endPoints) 
                                                         return ((endPointAt ix ^= Just (chan, endPointState)) $ st, ix)
  let addr = EndPointAddress . BSC.pack $ host ++ ":" ++ port ++ ":" ++ show endPointIx
  return . Right $ EndPoint { receive = readChan chan  
                            , address = addr 
                            , connect = tcpConnect addr 
                            , newMulticastGroup     = return . Left $ newMulticastGroupError 
                            , resolveMulticastGroup = \_ -> return . Left $ resolveMulticastGroupError
                            }
  where
    newMulticastGroupError     = FailedWith NewMulticastGroupUnsupported "TCP does not support multicast" 
    resolveMulticastGroupError = FailedWith ResolveMulticastGroupUnsupported "TCP does not support multicast" 
    

-- | Connnect to an endpoint
tcpConnect :: EndPointAddress -> EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
tcpConnect myAddress theirAddress _ = runErrorT $ do
  sock   <- socketForEndPoint myAddress theirAddress 
  -- TODO: test this failure
  connIx <- maybeTToErrorT (FailedWith undefined undefined) $ requestNewConnection sock
  return $ Connection { send  = sendWithLength sock (Just connIx)
                      , close = N.sClose sock 
                      }

-- | Request a new connection 
requestNewConnection :: N.Socket -> MaybeT IO ByteString 
requestNewConnection sock = do
  liftIO $ pure <$> encodeInt16 0 >>= NBS.sendMany sock
  BS.concat <$> recvExact sock 2

-- | Find a socket to the specified endpoint
--
-- TODOs:
-- * Reuse connections
-- * Hints?
socketForEndPoint :: EndPointAddress -- ^ Our address 
                  -> EndPointAddress -- ^ Their address
                  -> ErrorT (FailedWith ConnectErrorCode) IO N.Socket
socketForEndPoint (EndPointAddress myAddress) theirAddress = do
    (host, port, endPointIx) <- maybeToErrorT invalidAddress (decodeEndPointAddress theirAddress)
    liftIO $ do
      -- Connect to the destination transport 
      addr:_ <- N.getAddrInfo Nothing (Just host) (Just port) 
      sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
      N.setSocketOption sock N.ReuseAddr 1
      N.connect sock (N.addrAddress addr) 
      -- Tell it what endpoint we're interested in and our own address
      endPointBS <- encodeInt16 (fromIntegral endPointIx)
      sendWithLength sock (Just endPointBS) [myAddress]
      -- Connection is now established
      return sock 
  where
    invalidAddress = FailedWith ConnectInvalidAddress "Invalid address"

-- | Decode end point address
-- TODO: This uses regular expression parsing, which is nice, but unnecessary
decodeEndPointAddress :: EndPointAddress -> Maybe (N.HostName, N.ServiceName, EndPointIx)
decodeEndPointAddress (EndPointAddress bs) = match endPointAddressRE (BSC.unpack bs) 
  where
    endPointAddressRE :: RE Char (N.HostName, N.ServiceName, EndPointIx)
    endPointAddressRE = (,,) <$> few anySym <*> (sym ':' *> few anySym) <*> (sym ':' *> (read <$> many anySym))

