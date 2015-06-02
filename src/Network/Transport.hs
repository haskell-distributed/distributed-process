{-# LANGUAGE DeriveGeneric #-}
-- | Network Transport
module Network.Transport
  ( -- * Types
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
import qualified Data.ByteString as BS (copy)
import qualified Data.ByteString.Char8 as BSC (unpack)
import Control.DeepSeq (NFData(rnf))
import Control.Exception (Exception)
import Control.Applicative ((<$>))
import Data.Typeable (Typeable)
import Data.Binary (Binary(..))
import Data.Hashable
import Data.Word (Word64)
import Data.Data (Data)
import GHC.Generics (Generic)

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
    --
    -- 'connect' should be as asynchronous as possible; for instance, in
    -- Transport implementations based on some heavy-weight underlying network
    -- protocol (TCP, ssh), a call to 'connect' should be asynchronous when a
    -- heavyweight connection has already been established.
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
    --
    -- 'send' provides vectored I/O, and allows multiple data segments to be
    -- sent using a single call (cf. 'Network.Socket.ByteString.sendMany').
    -- Note that this segment structure is entirely unrelated to the segment
    -- structure /returned/ by a 'Received' event.
    send :: [ByteString] -> IO (Either (TransportError SendErrorCode) ())
    -- | Close the connection.
  , close :: IO ()
  }

-- | Event on an endpoint.
data Event =
    -- | Received a message
    Received {-# UNPACK #-} !ConnectionId [ByteString]
    -- | Connection closed
  | ConnectionClosed {-# UNPACK #-} !ConnectionId
    -- | Connection opened
    --
    -- 'ConnectionId's need not be allocated contiguously.
  | ConnectionOpened {-# UNPACK #-} !ConnectionId Reliability EndPointAddress
    -- | Received multicast
  | ReceivedMulticast MulticastAddress [ByteString]
    -- | The endpoint got closed (manually, by a call to closeEndPoint or closeTransport)
  | EndPointClosed
    -- | An error occurred
  | ErrorEvent (TransportError EventErrorCode)
  deriving (Show, Eq, Generic)

instance Binary Event

-- | Connection data ConnectHintsIDs enable receivers to distinguish one connection from another.
type ConnectionId = Word64

-- | Reliability guarantees of a connection.
data Reliability =
    ReliableOrdered
  | ReliableUnordered
  | Unreliable
  deriving (Show, Eq, Typeable, Generic)

instance Binary Reliability
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
  deriving (Eq, Ord, Typeable, Data, Hashable)

instance Binary EndPointAddress where
  put = put . endPointAddressToByteString
  get = EndPointAddress . BS.copy <$> get

instance Show EndPointAddress where
  show = BSC.unpack . endPointAddressToByteString

instance NFData EndPointAddress where rnf x = x `seq` ()

-- | EndPointAddress of a multicast group.
newtype MulticastAddress = MulticastAddress { multicastAddressToByteString :: ByteString }
  deriving (Eq, Ord, Generic)

instance Binary MulticastAddress

instance Show MulticastAddress where
  show = show . multicastAddressToByteString

--------------------------------------------------------------------------------
-- Hints                                                                      --
--                                                                            --
-- Hints provide transport-generic "suggestions". For now, these are          --
-- placeholders only.                                                         --
--------------------------------------------------------------------------------

-- | Hints used by 'connect'
data ConnectHints = ConnectHints {
    -- Timeout
    connectTimeout :: Maybe Int
  }

-- | Default hints for connecting
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
  deriving (Show, Typeable, Generic)

instance (Binary error) => Binary (TransportError error)

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
    -- | We lost connection to another endpoint
    --
    -- Although "Network.Transport" provides multiple independent lightweight
    -- connections between endpoints, those connections cannot /fail/
    -- independently: once one connection has failed, /all/ connections, in
    -- both directions, must now be considered to have failed; they fail as a
    -- "bundle" of connections, with only a single "bundle" of connections per
    -- endpoint at any point in time.
    --
    -- That is, suppose there are multiple connections in either direction
    -- between endpoints A and B, and A receives a notification that it has
    -- lost contact with B. Then A must not be able to send any further
    -- messages to B on existing connections.
    --
    -- Although B may not realize /immediately/ that its connection to A has
    -- been broken, messages sent by B on existing connections should not be
    -- delivered, and B must eventually get an EventConnectionLost message,
    -- too.
    --
    -- Moreover, this event must be posted before A has successfully
    -- reconnected (in other words, if B notices a reconnection attempt from A,
    -- it must post the EventConnectionLost before acknowledging the connection
    -- from A) so that B will not receive events about new connections or
    -- incoming messages from A without realizing that it got disconnected.
    --
    -- If B attempts to establish another connection to A before it realized
    -- that it got disconnected from A then it's okay for this connection
    -- attempt to fail, and the EventConnectionLost to be posted at that point,
    -- or for the EventConnectionLost to be posted and for the new connection
    -- to be considered the first connection of the "new bundle".
  | EventConnectionLost EndPointAddress
  deriving (Show, Typeable, Eq, Generic)

instance Binary EventErrorCode
