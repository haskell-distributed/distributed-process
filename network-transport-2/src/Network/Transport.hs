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
                         , TransportError(..)
                         , NewEndPointErrorCode(..)
                         , ConnectErrorCode(..)
                         , NewMulticastGroupErrorCode(..)
                         , ResolveMulticastGroupErrorCode(..)
                         , SendErrorCode(..)
                         , EventErrorCode(..)
                         ) where

import Data.ByteString (ByteString)
import Control.Exception (Exception)
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- Main API                                                                   --
--------------------------------------------------------------------------------

-- | To create a network abstraction layer, use one of the
-- @Network.Transport.*@ packages.
data Transport = Transport {
    -- | Create a new end point (heavyweight operation)
    newEndPoint :: IO (Either (TransportError NewEndPointErrorCode) EndPoint)
    -- | Shutdown the transport completely 
  , closeTransport :: IO () 
  }

-- | Network endpoint.
data EndPoint = EndPoint {
    -- | Endpoints have a single shared receive queue.
    receive :: IO Event
    -- | EndPointAddress of the endpoint.
  , address :: EndPointAddress 
    -- | Create a new lightweight connection. 
  , connect :: EndPointAddress -> Reliability -> IO (Either (TransportError ConnectErrorCode) Connection)
    -- | Create a new multicast group.
  , newMulticastGroup :: IO (Either (TransportError NewMulticastGroupErrorCode) MulticastGroup)
    -- | Resolve an address to a multicast group.
  , resolveMulticastGroup :: MulticastAddress -> IO (Either (TransportError ResolveMulticastGroupErrorCode) MulticastGroup)
    -- | Close the endpoint
  , closeEndPoint :: IO ()
  } 

-- | Lightweight connection to an endpoint.
data Connection = Connection {
    -- | Send a message on this connection.
    send :: [ByteString] -> IO (Either (TransportError SendErrorCode) ())
    -- | Close the connection.
  , close :: IO ()
  }

-- | Event on an endpoint.
data Event = 
    -- | Received a message
    Received ConnectionId [ByteString]
    -- | Connection closed
  | ConnectionClosed ConnectionId
    -- | Connection opened
  | ConnectionOpened ConnectionId Reliability EndPointAddress 
    -- | Received multicast
  | ReceivedMulticast MulticastAddress [ByteString]
    -- | The endpoint got closed (manually, by a call to closeEndPoint or closeTransport)
  | EndPointClosed
    -- | An error occurred 
  | ErrorEvent (TransportError EventErrorCode)  
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

data TransportError error = TransportError error String
  deriving (Show, Typeable)

-- | Although the functions in the transport API never throw TransportErrors
-- (but return them explicitly), application code may want to turn these into
-- exceptions. 
instance (Typeable err, Show err) => Exception (TransportError err)

-- | Errors during the creation of an endpoint
data NewEndPointErrorCode =
    -- | Not enough resources
    -- (i.e., this could be a temporary local problem)
    NewEndPointInsufficientResources
    -- | Failed for some other reason
    -- (i.e., there is probably no point trying again)
  | NewEndPointFailed 
  deriving (Show, Typeable)

-- | Connection failure 
data ConnectErrorCode = 
    -- | Could not resolve the address 
    -- (i.e., this could be a temporary remote problem)
    ConnectNotFound
    -- | Insufficient resources (for instance, no more sockets available)
    -- (i.e., this could be a temporary local problem)
  | ConnectInsufficientResources 
    -- | Failed for other reasons (including syntax error)
    -- (i.e., there is probably no point trying again).
  | ConnectFailed                
  deriving (Show, Typeable)

-- | Failure during the creation of a new multicast group
data NewMulticastGroupErrorCode =
    -- | Insufficient resources
    -- (i.e., this could be a temporary problem)
    NewMulticastGroupInsufficientResources
    -- | Failed for some other reason
    -- (i.e., there is probably no point trying again)
  | NewMulticastGroupFailed
    -- | Not all transport implementations support multicast
  | NewMulticastGroupUnsupported
  deriving (Show, Typeable)

-- | Failure during the resolution of a multicast group
data ResolveMulticastGroupErrorCode =
    -- | Multicast group not found
    -- (i.e., this could be a temporary problem)
    ResolveMulticastGroupNotFound
    -- | Failed for some other reason (including syntax error)
    -- (i.e., there is probably no point trying again)
  | ResolveMulticastGroupFailed
    -- | Not all transport implementations support multicast 
  | ResolveMulticastGroupUnsupported
  deriving (Show, Typeable)

-- | Failure during sending a message
data SendErrorCode =
    -- | Could not send this message
    -- (but another attempt might succeed)
    SendUnreachable
    -- | Send failed for some other reason
    -- (and retrying probably won't help)
  | SendFailed            
  deriving (Show, Typeable)

-- | Error codes used when reporting errors to endpoints (through receive)
data EventErrorCode = 
    -- | Failure of the entire endpoint 
    EventEndPointFailed
    -- | Transport-wide fatal error
  | EventTransportFailed
    -- | Connection to a remote endpoint was lost
  | EventConnectionLost EndPointAddress [ConnectionId] 
  deriving Show
