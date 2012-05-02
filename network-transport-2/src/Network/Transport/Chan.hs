-- | In-memory implementation of the Transport API.
module Network.Transport.Chan (createTransport) where

import Network.Transport 
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Applicative ((<$>))
import Control.Category ((>>>))
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, modifyMVar_, readMVar)
import Control.Monad (forM_, when)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, size, delete, findWithDefault)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC (pack)
import Data.Lens.Lazy (Lens, lens, (^.), (^%=), (^=), (^+=), mapLens)

-- Global state: next available "address", mapping from addresses to channels and next available connection
data TransportState = State { _channels         :: Map EndPointAddress (Chan Event) 
                            , _nextConnectionId :: Map EndPointAddress ConnectionId 
                            , _multigroups      :: Map MulticastAddress (MVar [Chan Event])
                            }

channels :: Lens TransportState (Map EndPointAddress (Chan Event))
channels = lens _channels (\ch st -> st { _channels = ch })

nextConnectionId :: Lens TransportState (Map EndPointAddress ConnectionId)
nextConnectionId = lens  _nextConnectionId (\cid st -> st { _nextConnectionId = cid })

multigroups :: Lens TransportState (Map MulticastAddress (MVar [Chan Event]))
multigroups = lens _multigroups (\gs st -> st { _multigroups = gs }) 

at :: Ord k => k -> String -> Lens (Map k v) v
at k err = lens (Map.findWithDefault (error err) k) (Map.insert k)   

channelAt :: EndPointAddress -> Lens TransportState (Chan Event) 
channelAt addr = channels >>> at addr "Invalid channel"

nextConnectionIdAt :: EndPointAddress -> Lens TransportState ConnectionId
nextConnectionIdAt addr = nextConnectionId >>> at addr "Invalid connection ID"

multigroupAt :: MulticastAddress -> Lens TransportState (MVar [Chan Event])
multigroupAt addr = multigroups >>> at addr "Invalid multigroup"

-- | Create a new Transport.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport :: IO Transport
createTransport = do
  state <- newMVar State { _channels         = Map.empty 
                         , _nextConnectionId = Map.empty
                         , _multigroups      = Map.empty
                         }
  return Transport { newEndPoint = apiNewEndPoint state }

-- | Create a new end point
apiNewEndPoint :: MVar TransportState -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
apiNewEndPoint state = do
  chan <- newChan
  addr <- modifyMVar state $ \st -> do
    let addr = EndPointAddress . BSC.pack . show . Map.size $ st ^. channels
    return ((channelAt addr ^= chan) . (nextConnectionIdAt addr ^= 1) $ st, addr)
  return . Right $ EndPoint { receive = readChan chan  
                            , address = addr
                            , connect = apiConnect addr state 
                            , newMulticastGroup     = apiNewMulticastGroup state chan
                            , resolveMulticastGroup = apiResolveMulticastGroup state chan 
                            }
  
-- | Create a new connection
apiConnect :: EndPointAddress -> MVar TransportState -> EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
apiConnect myAddress state theirAddress _ = do 
  (chan, conn) <- modifyMVar state $ \st -> do
    let chan = st ^. channelAt theirAddress
    let conn = st ^. nextConnectionIdAt theirAddress
    return (nextConnectionIdAt theirAddress ^+= 1 $ st, (chan, conn))
  writeChan chan $ ConnectionOpened conn ReliableOrdered myAddress
  connAlive <- newMVar True
  return . Right $ Connection { send  = apiSend chan conn connAlive 
                              , close = apiClose chan conn connAlive 
                              } 

-- | Send a message over a connection
apiSend :: Chan Event -> ConnectionId -> MVar Bool -> [ByteString] -> IO (Either (FailedWith SendErrorCode) ())
apiSend chan conn connAlive msg = 
  modifyMVar connAlive $ \alive -> do
    if alive 
      then do writeChan chan (Received conn msg)
              return (alive, Right ())
      else do return (alive, Left (FailedWith SendConnectionClosed "Connection closed"))

-- | Close a connection
apiClose :: Chan Event -> ConnectionId -> MVar Bool -> IO ()
apiClose chan conn connAlive = 
  modifyMVar_ connAlive $ \alive -> do
    when alive . writeChan chan $ ConnectionClosed conn
    return False

-- | Create a new multicast group
apiNewMulticastGroup :: MVar TransportState -> Chan Event -> IO (Either (FailedWith NewMulticastGroupErrorCode) MulticastGroup)
apiNewMulticastGroup state endpoint = do
  group <- newMVar []
  addr  <- modifyMVar state $ \st -> do
    let addr = MulticastAddress . BSC.pack . show . Map.size $ st ^. multigroups
    return (multigroupAt addr ^= group $ st, addr)
  return . Right $ createMulticastGroup state endpoint addr group

-- | Construct a multicast group
--
-- When the group is deleted some endpoints may still receive messages, but
-- subsequent calls to resolveMulticastGroup will fail. This mimicks the fact
-- that some multicast messages may still be in transit when the group is
-- deleted.
--
-- TODO: subscribing twice means you will receive messages twice, but as soon
-- as you unsubscribe you will stop receiving all messages. Not sure if this
-- is the right behaviour.
createMulticastGroup :: MVar TransportState -> Chan Event -> MulticastAddress -> MVar [Chan Event] -> MulticastGroup
createMulticastGroup state endpoint addr group =
  MulticastGroup { multicastAddress     = addr 
                 , deleteMulticastGroup = modifyMVar_ state $ return . (multigroups ^%= Map.delete addr)
                 , maxMsgSize           = Nothing
                 , multicastSend        = \payload -> do 
                                            cs <- readMVar group 
                                            forM_ cs $ \ch -> writeChan ch (ReceivedMulticast addr payload)             
                 , multicastSubscribe   = modifyMVar_ group $ return . (endpoint :)
                 , multicastUnsubscribe = modifyMVar_ group $ return . filter (/= endpoint) 
                 , multicastClose       = return () 
                 }

-- | Resolve a multicast group
apiResolveMulticastGroup :: MVar TransportState 
                          -> Chan Event 
                          -> MulticastAddress 
                          -> IO (Either (FailedWith ResolveMulticastGroupErrorCode) MulticastGroup)
apiResolveMulticastGroup state endpoint addr = do
  group <- (^. (multigroups >>> mapLens addr)) <$> readMVar state 
  case group of
    Nothing   -> return . Left $ FailedWith ResolveMulticastGroupNotFound ("Group " ++ show addr ++ " not found")
    Just mvar -> return . Right $ createMulticastGroup state endpoint addr mvar 
