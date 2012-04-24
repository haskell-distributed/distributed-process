-- | In-memory implementation of the Transport API.
module Network.Transport.Chan (createTransport) where

import Network.Transport 
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Applicative ((<$>))
import Control.Category ((>>>))
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, modifyMVar_, readMVar)
import Control.Monad (forM_)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, (!), size, delete)
import qualified Data.ByteString.Char8 as BSC (pack)
import Data.Lens.Lazy (Lens, lens, (^.), (^%=), (^=), (^+=), mapLens)

-- Global state: next available "address", mapping from addresses to channels and next available connection
data TransportState = State { _channels    :: Map EndPointAddress (Chan Event) 
                            , _connections :: Map EndPointAddress Int
                            , _multigroups :: Map MulticastAddress (MVar [Chan Event])
                            }

channels :: Lens TransportState (Map EndPointAddress (Chan Event))
channels = lens _channels (\ch st -> st { _channels = ch })

connections :: Lens TransportState (Map EndPointAddress Int)
connections = lens _connections (\conn st -> st { _connections = conn })

multigroups :: Lens TransportState (Map MulticastAddress (MVar [Chan Event]))
multigroups = lens _multigroups (\gs st -> st { _multigroups = gs }) 

at :: Ord k => k -> Lens (Map k v) v
at k = lens (Map.! k) (Map.insert k)   

channelAt :: EndPointAddress -> Lens TransportState (Chan Event) 
channelAt addr = channels >>> at addr

connectionAt :: EndPointAddress -> Lens TransportState Int
connectionAt addr = connections >>> at addr

multigroupAt :: MulticastAddress -> Lens TransportState (MVar [Chan Event])
multigroupAt addr = multigroups >>> at addr

-- | Create a new Transport.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport :: IO Transport
createTransport = do
  state <- newMVar State { _channels    = Map.empty 
                         , _connections = Map.empty
                         , _multigroups = Map.empty
                         }
  return Transport { newEndPoint = chanNewEndPoint state }

-- Create a new end point
chanNewEndPoint :: MVar TransportState -> IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
chanNewEndPoint state = do
  chan <- newChan
  addr <- modifyMVar state $ \st -> do
    let addr = EndPointAddress . BSC.pack . show . Map.size $ st ^. channels
    return ((channelAt addr ^= chan) . (connectionAt addr ^= 0) $ st, addr)
  return . Right $ EndPoint { receive = readChan chan  
                            , address = addr
                            , connect = chanConnect addr state 
                            , newMulticastGroup     = chanNewMulticastGroup state chan
                            , resolveMulticastGroup = chanResolveMulticastGroup state chan 
                            }
  
-- Create a new connection
chanConnect :: EndPointAddress -> MVar TransportState -> EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
chanConnect myAddress state theirAddress _ = do 
  (chan, conn) <- modifyMVar state $ \st -> do
    let chan = st ^. channelAt theirAddress
    let conn = st ^. connectionAt theirAddress
    return (connectionAt theirAddress ^+= 1 $ st, (chan, conn))
  writeChan chan $ ConnectionOpened conn ReliableOrdered myAddress
  return . Right $ Connection { send  = \msg -> do writeChan chan (Received conn msg)
                                                   return (Right ())
                              , close = writeChan chan $ ConnectionClosed conn
                              } 

-- Create a new multicast group
chanNewMulticastGroup :: MVar TransportState -> Chan Event -> IO (Either (FailedWith NewMulticastGroupErrorCode) MulticastGroup)
chanNewMulticastGroup state endpoint = do
  group <- newMVar []
  addr  <- modifyMVar state $ \st -> do
    let addr = MulticastAddress . BSC.pack . show . Map.size $ st ^. multigroups
    return (multigroupAt addr ^= group $ st, addr)
  return . Right $ chanMulticastGroup state endpoint addr group

-- Construct a multicast group
--
-- When the group is deleted some endpoints may still receive messages, but
-- subsequent calls to resolveMulticastGroup will fail. This mimicks the fact
-- that some multicast messages may still be in transit when the group is
-- deleted.
--
-- TODO: subscribing twice means you will receive messages twice, but as soon
-- as you unsubscribe you will stop receiving all messages. Not sure if this
-- is the right behaviour.
chanMulticastGroup :: MVar TransportState -> Chan Event -> MulticastAddress -> MVar [Chan Event] -> MulticastGroup
chanMulticastGroup state endpoint addr group =
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

-- Resolve a multicast group
chanResolveMulticastGroup :: MVar TransportState 
                          -> Chan Event 
                          -> MulticastAddress 
                          -> IO (Either (FailedWith ResolveMulticastGroupErrorCode) MulticastGroup)
chanResolveMulticastGroup state endpoint addr = do
  group <- (^. (multigroups >>> mapLens addr)) <$> readMVar state 
  case group of
    Nothing   -> return . Left $ FailedWith ResolveMulticastGroupNotFound ("Group " ++ show addr ++ " not found")
    Just mvar -> return . Right $ chanMulticastGroup state endpoint addr mvar 
