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
                           -- * Hints
                         , ConnectHints(..)
                         , defaultConnectHints
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
  , connect :: EndPointAddress -> Reliability -> ConnectHints -> IO (Either (TransportError ConnectErrorCode) Connection)
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
  deriving (Show, Eq)

-- | Connection data ConnectHintsIDs enable receivers to distinguish one connection from another.
type ConnectionId = Int

-- | Reliability guarantees of a connection.
data Reliability = 
    ReliableOrdered 
  | ReliableUnordered 
  | Unreliable
  deriving (Show, Eq)

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
  deriving (Eq, Ord)

instance Show EndPointAddress where
  show = show . endPointAddressToByteString

-- | EndPointAddress of a multicast group.
newtype MulticastAddress = MulticastAddress { multicastAddressToByteString :: ByteString }
  deriving (Eq, Ord)

instance Show MulticastAddress where
  show = show . multicastAddressToByteString

--------------------------------------------------------------------------------
-- Hints                                                                      --
--                                                                            --
-- Hints provide transport-generic "suggestions". For now, these are          --
-- placeholders only.                                                         --
--------------------------------------------------------------------------------

-- Hints used by 'connect'
data ConnectHints = ConnectHints {
    -- Timeout
    connectTimeout :: Maybe Int
  }

-- Default hints for connecting
defaultConnectHints :: ConnectHints
defaultConnectHints = ConnectHints {
    connectTimeout = Nothing
  }

--------------------------------------------------------------------------------
-- Error codes                                                                --
--                                                                            --
-- Errors should be transport-implementation independent. The deciding factor --
-- for distinguishing one kind of error from another should be: might         --
-- application code have to take a different action depending on the kind of  --
-- error?                                                                     --
--------------------------------------------------------------------------------

-- | Errors returned by Network.Transport API functions consist of an error
-- code and a human readable description of the problem 
data TransportError error = TransportError error String
  deriving (Show, Typeable)

-- | Although the functions in the transport API never throw TransportErrors
-- (but return them explicitly), application code may want to turn these into
-- exceptions. 
instance (Typeable err, Show err) => Exception (TransportError err)

-- | When comparing errors we ignore the human-readable strings
instance Eq error => Eq (TransportError error) where
  TransportError err1 _ == TransportError err2 _ = err1 == err2

-- | Errors during the creation of an endpoint
data NewEndPointErrorCode =
    -- | Not enough resources
    NewEndPointInsufficientResources
    -- | Failed for some other reason
  | NewEndPointFailed 
  deriving (Show, Typeable, Eq)

-- | Connection failure 
data ConnectErrorCode = 
    -- | Could not resolve the address 
    ConnectNotFound
    -- | Insufficient resources (for instance, no more sockets available)
  | ConnectInsufficientResources 
    -- | Timeout
  | ConnectTimeout
    -- | Failed for other reasons (including syntax error)
  | ConnectFailed                
  deriving (Show, Typeable, Eq)

-- | Failure during the creation of a new multicast group
data NewMulticastGroupErrorCode =
    -- | Insufficient resources
    NewMulticastGroupInsufficientResources
    -- | Failed for some other reason
  | NewMulticastGroupFailed
    -- | Not all transport implementations support multicast
  | NewMulticastGroupUnsupported
  deriving (Show, Typeable, Eq)

-- | Failure during the resolution of a multicast group
data ResolveMulticastGroupErrorCode =
    -- | Multicast group not found
    ResolveMulticastGroupNotFound
    -- | Failed for some other reason (including syntax error)
  | ResolveMulticastGroupFailed
    -- | Not all transport implementations support multicast 
  | ResolveMulticastGroupUnsupported
  deriving (Show, Typeable, Eq)

-- | Failure during sending a message
data SendErrorCode =
    -- | Connection was closed
    SendClosed
    -- | Send failed for some other reason
  | SendFailed            
  deriving (Show, Typeable, Eq)

-- | Error codes used when reporting errors to endpoints (through receive)
data EventErrorCode = 
    -- | Failure of the entire endpoint 
    EventEndPointFailed
    -- | Transport-wide fatal error
  | EventTransportFailed
    -- | Connection to a remote endpoint was lost
  | EventConnectionLost EndPointAddress [ConnectionId] 
  deriving (Show, Typeable, Eq)
