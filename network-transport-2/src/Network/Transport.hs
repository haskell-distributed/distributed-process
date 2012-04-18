-- | Network Transport 
module Network.Transport where

import Data.ByteString (ByteString)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)

-- | To create a network abstraction layer, use one of the
-- @Network.Transport.*@ packages.
data Transport = Transport {
    -- | Create a new end point (heavyweight operation)
    newEndPoint :: IO (Either Error EndPoint)
  }

-- | Address of an endpoint.
newtype Address = Address ByteString
  deriving Show

-- | Address of a multicast group.
newtype MulticastAddress = MulticastAddress ByteString
  deriving Show

-- | Error codes (none defined at the moment).
data ErrorCode

-- | Error consisting of an error code and a human readable error string.
data Error = Error ErrorCode String 

-- | Network endpoint.
data EndPoint = EndPoint {
    -- | Endpoints have a single shared receive queue.
    receive :: IO Event
    -- | Address of the endpoint.
  , address :: Address 
    -- | Create a new lightweight connection. 
  , connect :: Address -> Reliability -> IO (Either Error Connection)
    -- | Create a new multicast group.
  , newMulticastGroup :: IO (Either Error MulticastGroup)
    -- | Resolve an address to a multicast group.
  , resolveMulticastGroup :: MulticastAddress -> IO (Either Error MulticastGroup)
  } 

-- | Reliability guarantees of a connection.
data Reliability = 
    ReliableOrdered 
  | ReliableUnordered 
  | Unreliable
  deriving Show

-- | Connection IDs enable receivers to distinguish one connection from another.
type ConnectionId = Int

-- | Lightweight connection to an endpoint.
data Connection = Connection {
    -- | Send a message on this connection.
    send  :: [ByteString] -> IO ()
    -- | Close the connection.
  , close :: IO ()
  }

-- | Event on an endpoint.
data Event = 
    Receive ConnectionId [ByteString]
  | ConnectionClosed ConnectionId
  | ConnectionOpened ConnectionId Reliability Address 
  | MulticastReceive MulticastAddress [ByteString]
  deriving Show

-- | Multicast group.
data MulticastGroup = MulticastGroup {
    -- | Address of the multicast group. 
    multicastAddress     :: MulticastAddress
    -- | Delete the multicast group completely.
  , deleteMulticastGroup :: IO ()
    -- | Maximum message size that we can send to this group.
  , maxMsgSize           :: Maybe Int 
    -- | Send a message to the group.
  , multicastSend        :: [ByteString] -> IO ()
    -- | Subscribe to the given multicast group (to start receiving messages from the group).
  , multicastSubscribe   :: IO ()
    -- | Unsubscribe from the given multicast group (to stop receiving messages from the group).
  , multicastUnsubscribe :: IO ()
    -- | Close the group (that is, indicate you no longer wish to send to the group).
  , multicastClose       :: IO ()
  }

-- | Fork a new thread, create a new end point on that thread, and run the specified IO operation on that thread.
-- 
-- Returns the address of the new end point.
spawn :: Transport -> (EndPoint -> IO ()) -> IO Address 
spawn transport proc = do
  addr <- newEmptyMVar
  forkIO $ do
    Right endpoint <- newEndPoint transport
    putMVar addr (address endpoint)
    proc endpoint
  takeMVar addr
