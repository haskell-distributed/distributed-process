-- | TCP transport
module Network.Transport.TCP where

import Network.Transport
import Network.Transport.Internal ( encodeInt16 
                                  , decodeInt16
                                  , encodeInt32
                                  , decodeInt32
                                  , maybeToErrorT
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , SocketType(Stream)
                                     , SocketOption(ReuseAddr)
                                     , getAddrInfo
                                     , defaultHints
                                     , socket
                                     , bindSocket
                                     , listen
                                     , addrFamily
                                     , addrAddress
                                     , defaultProtocol
                                     , setSocketOption
                                     , connect
                                     , sClose
                                     , accept
                                     )
import qualified Network.Socket.ByteString as NBS (sendMany, recv)
import Control.Concurrent (forkIO, ThreadId)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, readMVar)
import Control.Category ((>>>))
import Control.Applicative ((<*>), (*>), (<$>), pure)
import Control.Monad (forever, mzero)
import Control.Monad.Error (ErrorT, liftIO, runErrorT)
import Control.Monad.Trans.Maybe (MaybeT(MaybeT), runMaybeT)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import qualified Data.ByteString.Char8 as BSC (pack, unpack)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty, size)
import Data.Lens.Lazy (Lens, lens, intMapLens, (^.), (^=), (^+=))
import Data.Int (Int32)
import Text.Regex.Applicative (RE, few, anySym, sym, many, match)

data TransportState = TransportState { _endPoints        :: IntMap (Chan Event, MVar EndPointState) }
data EndPointState  = EndPointState  { _nextConnectionIx :: ConnectionIx }
type EndPointIx     = Int
type ConnectionIx   = Int

endPoints :: Lens TransportState (IntMap (Chan Event, MVar EndPointState))
endPoints = lens _endPoints (\es st -> st { _endPoints = es })

nextConnectionIx :: Lens EndPointState ConnectionIx
nextConnectionIx = lens _nextConnectionIx (\cix st -> st { _nextConnectionIx = cix })

endPointAt :: Int -> Lens TransportState (Maybe (Chan Event, MVar EndPointState))
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

-- | Start a server at the specified address
forkServer :: N.HostName -> N.ServiceName -> (N.Socket -> IO ()) -> IO ThreadId 
forkServer host port server = do
  -- Resolve the specified address. By specification, getAddrInfo will never
  -- return an empty list (but will throw an exception instead) and will return
  -- the "best" address first, whatever that means
  addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
  sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
  N.setSocketOption sock N.ReuseAddr 1
  N.bindSocket sock (N.addrAddress addr)
  N.listen sock 5
  forkIO $ server sock

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
    readMessage :: Int -> MaybeT IO ()
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
                            , newMulticastGroup     = undefined
                            , resolveMulticastGroup = undefined
                            }

-- | Connnect to an endpoint
tcpConnect :: EndPointAddress -> EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
tcpConnect myAddress theirAddress _ = runErrorT $ do
    sock   <- socketForEndPoint myAddress theirAddress 
    connIx <- liftIO $ requestNewConnection sock
    return $ Connection { send  = sendWithLength sock (Just connIx)
                        , close = N.sClose sock 
                        }

-- | Request a new connection 
requestNewConnection :: N.Socket -> IO ByteString 
requestNewConnection sock = do
  pure <$> encodeInt16 0 >>= NBS.sendMany sock
  NBS.recv sock 2

-- | Find a socket to the specified endpoint
--
-- TODOs:
-- * Reuse connections
-- * Hints?
socketForEndPoint :: EndPointAddress -- ^ Our address 
                  -> EndPointAddress -- ^ Their address
                  -> ErrorT (FailedWith ConnectErrorCode) IO N.Socket
socketForEndPoint (EndPointAddress myAddress) (EndPointAddress theirAddress) = do
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

-- | Send a bunch of bytestrings prepended with their length
sendWithLength :: N.Socket           -- ^ Socket to send on
               -> Maybe ByteString   -- ^ Optional header to send before the length
               -> [ByteString]       -- ^ Payload
               -> IO ()
sendWithLength sock header payload = do
  lengthBs <- encodeInt32 (fromIntegral . sum . map BS.length $ payload)
  let msg = maybe id (:) header $ lengthBs : payload
  NBS.sendMany sock msg 

-- | Read a length and then a payload of that length
-- TODO: error handling
recvWithLength :: N.Socket -> MaybeT IO [ByteString]
recvWithLength sock = do
  msgLengthBs <- recvExact sock 4
  decodeInt32 (BS.concat msgLengthBs) >>= recvExact sock

-- | Decode end point address
-- TODO: This uses regular expression parsing, which is nice, but unnecessary
decodeEndPointAddress :: ByteString -> Maybe (N.HostName, N.ServiceName, Int)
decodeEndPointAddress bs = match endPointAddressRE (BSC.unpack bs) 
  where
    endPointAddressRE :: RE Char (N.HostName, N.ServiceName, Int)
    endPointAddressRE = (,,) <$> few anySym <*> (sym ':' *> few anySym) <*> (sym ':' *> (read <$> many anySym))

-- | Read an exact number of bytes from a socket
--
-- Returns 'Nothing' if the socket closes prematurely.
recvExact :: N.Socket                -- ^ Socket to read from 
          -> Int32                   -- ^ Number of bytes to read
          -> MaybeT IO [ByteString]
recvExact sock len = do
    (socketClosed, input) <- liftIO $ go [] len
    if socketClosed then mzero else return input
  where
    -- Returns input read and whether the socket closed prematurely
    go :: [ByteString] -> Int32 -> IO (Bool, [ByteString])
    go acc 0 = return (False, reverse acc)
    go acc l = do
      bs <- NBS.recv sock (fromIntegral l `min` 4096)
      if BS.null bs 
        then return (True, reverse acc)
        else go (bs : acc) (l - (fromIntegral $ BS.length bs))
