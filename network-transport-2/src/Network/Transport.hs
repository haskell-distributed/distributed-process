-- | Network Transport 
module Network.Transport ( -- * Types
                           Transport(..)
                         , EndPoint(..)
                         , Connection(..)
                         , Event(..)
                         , ConnectionId
                         , Reliability(..)
                         , MulticastGroup(..)
                         , EndPointAddress(..)
                         , MulticastAddress(..)
                           -- * Error codes
                         , FailedWith(..)
                         , NewEndPointErrorCode
                         , ConnectErrorCode(..)
                         , NewMulticastGroupErrorCode(..)
                         , ResolveMulticastGroupErrorCode(..)
                         , SendErrorCode(..)
                         ) where

import Data.ByteString (ByteString)
import Control.Monad.Error (Error(..))

--------------------------------------------------------------------------------
-- Main API                                                                   --
--------------------------------------------------------------------------------

-- | To create a network abstraction layer, use one of the
-- @Network.Transport.*@ packages.
data Transport = Transport {
    -- | Create a new end point (heavyweight operation)
    newEndPoint :: IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
  }

-- | Network endpoint.
data EndPoint = EndPoint {
    -- | Endpoints have a single shared receive queue.
    receive :: IO Event
    -- | EndPointAddress of the endpoint.
  , address :: EndPointAddress 
    -- | Create a new lightweight connection. 
  , connect :: EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
    -- | Create a new multicast group.
  , newMulticastGroup :: IO (Either (FailedWith NewMulticastGroupErrorCode) MulticastGroup)
    -- | Resolve an address to a multicast group.
  , resolveMulticastGroup :: MulticastAddress -> IO (Either (FailedWith ResolveMulticastGroupErrorCode) MulticastGroup)
  } 

-- | Lightweight connection to an endpoint.
data Connection = Connection {
    -- | Send a message on this connection.
    send  :: [ByteString] -> IO (Either (FailedWith SendErrorCode) ())
    -- | Close the connection.
  , close :: IO ()
  }

-- | Event on an endpoint.
data Event = 
    Received ConnectionId [ByteString]
  | ConnectionClosed ConnectionId
  | ConnectionOpened ConnectionId Reliability EndPointAddress 
  | ReceivedMulticast MulticastAddress [ByteString]
  deriving Show

-- | Connection IDs enable receivers to distinguish one connection from another.
type ConnectionId = Int

-- | Reliability guarantees of a connection.
data Reliability = 
    ReliableOrdered 
  | ReliableUnordered 
  | Unreliable
  deriving Show

-- | Multicast group.
data MulticastGroup = MulticastGroup {
    -- | EndPointAddress of the multicast group. 
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

-- | EndPointAddress of an endpoint.
newtype EndPointAddress = EndPointAddress { endPointAddressToByteString :: ByteString }
  deriving (Show, Eq, Ord)

-- | EndPointAddress of a multicast group.
newtype MulticastAddress = MulticastAddress { multicastAddressToByteString :: ByteString }
  deriving (Show, Eq, Ord)

--------------------------------------------------------------------------------
-- Error codes                                                                --
--------------------------------------------------------------------------------

data FailedWith error = FailedWith error String
  deriving Show

instance Error (FailedWith error) where
  strMsg = FailedWith undefined

-- | Errors during the creation of an endpoint (currently, there are none)
data NewEndPointErrorCode 

-- | Connection failure 
data ConnectErrorCode = 
    ConnectInvalidAddress        -- ^ Could not parse or resolve the address 
  | ConnectInsufficientResources -- ^ Insufficient resources (for instance, no more sockets available)
  | ConnectFailed                -- ^ Failed for other reasons 
  deriving Show

-- | Failure during the creation of a new multicast group
data NewMulticastGroupErrorCode =
    NewMulticastGroupUnsupported
  deriving Show

-- | Failure during the resolution of a multicast group
data ResolveMulticastGroupErrorCode =
    ResolveMulticastGroupNotFound
  | ResolveMulticastGroupUnsupported
  deriving Show

-- | Failure during sending a message
data SendErrorCode =
    SendFailed
  | SendConnectionClosed
  deriving Show
