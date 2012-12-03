-- | In-memory implementation of the Transport API.
module Network.Transport.Chan (createTransport) where

import Network.Transport
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Applicative ((<$>))
import Control.Category ((>>>))
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, modifyMVar_, readMVar)
import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, size, delete, findWithDefault)
import Data.Set (Set)
import qualified Data.Set as Set (empty, elems, insert, delete)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC (pack)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe)

-- Global state: next available "address", mapping from addresses to channels and next available connection
data TransportState = State { _channels         :: Map EndPointAddress (Chan Event)
                            , _nextConnectionId :: Map EndPointAddress ConnectionId
                            , _multigroups      :: Map MulticastAddress (MVar (Set EndPointAddress))
                            }

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
  return Transport { newEndPoint    = apiNewEndPoint state
                   , closeTransport = throwIO (userError "closeEndPoint not implemented")
                   }

-- | Create a new end point
apiNewEndPoint :: MVar TransportState -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint state = do
  chan <- newChan
  addr <- modifyMVar state $ \st -> do
    let addr = EndPointAddress . BSC.pack . show . Map.size $ st ^. channels
    return ((channelAt addr ^= chan) . (nextConnectionIdAt addr ^= 1) $ st, addr)
  return . Right $ EndPoint { receive       = readChan chan
                            , address       = addr
                            , connect       = apiConnect addr state
                            , closeEndPoint = throwIO (userError "closeEndPoint not implemented")
                            , newMulticastGroup     = apiNewMulticastGroup state addr
                            , resolveMulticastGroup = apiResolveMulticastGroup state addr
                            }

-- | Create a new connection
apiConnect :: EndPointAddress
           -> MVar TransportState
           -> EndPointAddress
           -> Reliability
           -> ConnectHints
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect myAddress state theirAddress _reliability _hints = do
  (chan, conn) <- modifyMVar state $ \st -> do
    let chan = st ^. channelAt theirAddress
    let conn = st ^. nextConnectionIdAt theirAddress
    return (nextConnectionIdAt theirAddress ^: (+ 1) $ st, (chan, conn))
  writeChan chan $ ConnectionOpened conn ReliableOrdered myAddress
  connAlive <- newMVar True
  return . Right $ Connection { send  = apiSend chan conn connAlive
                              , close = apiClose chan conn connAlive
                              }

-- | Send a message over a connection
apiSend :: Chan Event -> ConnectionId -> MVar Bool -> [ByteString] -> IO (Either (TransportError SendErrorCode) ())
apiSend chan conn connAlive msg =
  modifyMVar connAlive $ \alive ->
    if alive
      then do
        writeChan chan (Received conn msg)
        return (alive, Right ())
      else
        return (alive, Left (TransportError SendFailed "Connection closed"))

-- | Close a connection
apiClose :: Chan Event -> ConnectionId -> MVar Bool -> IO ()
apiClose chan conn connAlive =
  modifyMVar_ connAlive $ \alive -> do
    when alive . writeChan chan $ ConnectionClosed conn
    return False

-- | Create a new multicast group
apiNewMulticastGroup :: MVar TransportState -> EndPointAddress -> IO (Either (TransportError NewMulticastGroupErrorCode) MulticastGroup)
apiNewMulticastGroup state ourAddress = do
  group <- newMVar Set.empty
  groupAddr <- modifyMVar state $ \st -> do
    let addr = MulticastAddress . BSC.pack . show . Map.size $ st ^. multigroups
    return (multigroupAt addr ^= group $ st, addr)
  return . Right $ createMulticastGroup state ourAddress groupAddr group

-- | Construct a multicast group
--
-- When the group is deleted some endpoints may still receive messages, but
-- subsequent calls to resolveMulticastGroup will fail. This mimicks the fact
-- that some multicast messages may still be in transit when the group is
-- deleted.
createMulticastGroup :: MVar TransportState -> EndPointAddress -> MulticastAddress -> MVar (Set EndPointAddress) -> MulticastGroup
createMulticastGroup state ourAddress groupAddress group =
  MulticastGroup { multicastAddress     = groupAddress
                 , deleteMulticastGroup = modifyMVar_ state $ return . (multigroups ^: Map.delete groupAddress)
                 , maxMsgSize           = Nothing
                 , multicastSend        = \payload -> do
                                            cs <- (^. channels) <$> readMVar state
                                            es <- readMVar group
                                            forM_ (Set.elems es) $ \ep -> do
                                              let ch = cs ^. at ep "Invalid endpoint"
                                              writeChan ch (ReceivedMulticast groupAddress payload)
                 , multicastSubscribe   = modifyMVar_ group $ return . Set.insert ourAddress
                 , multicastUnsubscribe = modifyMVar_ group $ return . Set.delete ourAddress
                 , multicastClose       = return ()
                 }

-- | Resolve a multicast group
apiResolveMulticastGroup :: MVar TransportState
                         -> EndPointAddress
                         -> MulticastAddress
                         -> IO (Either (TransportError ResolveMulticastGroupErrorCode) MulticastGroup)
apiResolveMulticastGroup state ourAddress groupAddress = do
  group <- (^. (multigroups >>> DAC.mapMaybe groupAddress)) <$> readMVar state
  case group of
    Nothing   -> return . Left $ TransportError ResolveMulticastGroupNotFound ("Group " ++ show groupAddress ++ " not found")
    Just mvar -> return . Right $ createMulticastGroup state ourAddress groupAddress mvar

--------------------------------------------------------------------------------
-- Lens definitions                                                           --
--------------------------------------------------------------------------------

channels :: Accessor TransportState (Map EndPointAddress (Chan Event))
channels = accessor _channels (\ch st -> st { _channels = ch })

nextConnectionId :: Accessor TransportState (Map EndPointAddress ConnectionId)
nextConnectionId = accessor  _nextConnectionId (\cid st -> st { _nextConnectionId = cid })

multigroups :: Accessor TransportState (Map MulticastAddress (MVar (Set EndPointAddress)))
multigroups = accessor _multigroups (\gs st -> st { _multigroups = gs })

at :: Ord k => k -> String -> Accessor (Map k v) v
at k err = accessor (Map.findWithDefault (error err) k) (Map.insert k)

channelAt :: EndPointAddress -> Accessor TransportState (Chan Event)
channelAt addr = channels >>> at addr "Invalid channel"

nextConnectionIdAt :: EndPointAddress -> Accessor TransportState ConnectionId
nextConnectionIdAt addr = nextConnectionId >>> at addr "Invalid connection ID"

multigroupAt :: MulticastAddress -> Accessor TransportState (MVar (Set EndPointAddress))
multigroupAt addr = multigroups >>> at addr "Invalid multigroup"

