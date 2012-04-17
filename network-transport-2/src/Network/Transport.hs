-- | Network Transport 
--
-- Connections are as light-weight as possible. That is, for a UDP
-- implementation they are practically free (only a single socket is
-- created per end point). For a TCP implementation the Transport guarantees
-- that only a single socket pair will be created for every pair of end
-- points.
module Network.Transport where

import Data.ByteString (ByteString)

-- | To create a network abstraction layer, use one of the
-- Network.Transport.* packages.
data Transport = Transport {
  newEndPoint :: Identity -> IO (Either Error EndPoint)
}

-- | Every end point must have a unique identity.
type Identity = ByteString 

newtype Address = Address ByteString

newtype MulticastAddress = MulticastAddress ByteString

data ErrorCode

data Error = Error ErrorCode String 

data EndPoint = EndPoint {
    receive :: IO Event
  , address :: Address 
  , connect :: Address -> Reliability -> IO (Either Error Connection)
  , multicastNewGroup    :: IO (Either Error MulticastGroup)
  , multicastConnect     :: MulticastAddress -> IO MulticastGroup
  , multicastSubscribe   :: MulticastAddress -> IO ()
  , multicastUnsubscribe :: MulticastAddress -> IO ()
} 

data Reliability = 
    ReliableOrdered 
  | ReliableUnordered 
  | Unreliable

type ConnectionId = Int

data Connection = Connection {
    connId :: ConnectionId 
  , send   :: [ByteString] -> IO ()
  , close  :: IO ()
  }

data Event = 
    Receive ConnectionId [ByteString]
  | ConnectionClosed ConnectionId
  | ConnectionOpened ConnectionId Reliability
  | MulticastReceive MulticastAddress [ByteString]

data MulticastGroup = MulticastGroup {
    multicastSend       :: [ByteString] -> IO ()
  , multicastAddress    :: MulticastAddress
  , multicastMaxMsgSize :: Maybe Int
  , multicastGroupClose :: IO ()
  }
