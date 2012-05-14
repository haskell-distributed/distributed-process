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
                         , NewEndPointErrorCode(..)
                         , ConnectErrorCode(..)
                         , NewMulticastGroupErrorCode(..)
                         , ResolveMulticastGroupErrorCode(..)
                         , SendErrorCode(..)
                         , ErrorEventInfo(..)
                         ) where

import Data.ByteString (ByteString)
import Control.Monad.Error (Error(..))
import Control.Exception (Exception)
import Data.Typeable (Typeable)

--------------------------------------------------------------------------------
-- Main API                                                                   --
--------------------------------------------------------------------------------

-- | To create a network abstraction layer, use one of the
-- @Network.Transport.*@ packages.
data Transport = Transport {
    -- | Create a new end point (heavyweight operation)
    newEndPoint :: IO (Either (FailedWith NewEndPointErrorCode) EndPoint)
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
  , connect :: EndPointAddress -> Reliability -> IO (Either (FailedWith ConnectErrorCode) Connection)
    -- | Create a new multicast group.
  , newMulticastGroup :: IO (Either (FailedWith NewMulticastGroupErrorCode) MulticastGroup)
    -- | Resolve an address to a multicast group.
  , resolveMulticastGroup :: MulticastAddress -> IO (Either (FailedWith ResolveMulticastGroupErrorCode) MulticastGroup)
    -- | Close the endpoint
  , closeEndPoint :: IO ()
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
    -- | Received a message
    Received ConnectionId [ByteString]
    -- | Connection closed
  | ConnectionClosed ConnectionId
    -- | Connection opened
  | ConnectionOpened ConnectionId Reliability EndPointAddress 
    -- | Received multicast
  | ReceivedMulticast MulticastAddress [ByteString]
    -- | Error that caused a bunch of connections to close (possibly none)
  | ErrorEvent ErrorEventInfo 
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
  deriving (Show, Typeable)

instance Error (FailedWith error) where
  strMsg = FailedWith undefined

-- | For internal convenience, FailedWith is declared as an exception type
instance (Typeable err, Show err) => Exception (FailedWith err)

-- | Errors during the creation of an endpoint (currently, there are none)
data NewEndPointErrorCode =
    NewEndPointTransportFailure  -- ^ Transport-wide failure 
  deriving (Show, Typeable)

-- | Connection failure 
data ConnectErrorCode = 
    ConnectInvalidAddress        -- ^ Could not parse or resolve the address 
  | ConnectInsufficientResources -- ^ Insufficient resources (for instance, no more sockets available)
  | ConnectFailed                -- ^ Failed for other reasons 
  deriving (Show, Typeable)

-- | Failure during the creation of a new multicast group
data NewMulticastGroupErrorCode =
    NewMulticastGroupUnsupported
  deriving (Show, Typeable)

-- | Failure during the resolution of a multicast group
data ResolveMulticastGroupErrorCode =
    ResolveMulticastGroupNotFound
  | ResolveMulticastGroupUnsupported
  deriving (Show, Typeable)

-- | Failure during sending a message
data SendErrorCode =
    SendConnectionClosed  -- ^ Connection was closed manually or because of an error
  | SendFailed            -- ^ Send failed for some other reason
  deriving (Show, Typeable)

-- | Error codes used when reporting errors to endpoints (through receive)
data ErrorEventInfo = 
    -- | Endpoint was closed (manually or because of an error)   
    ErrorEventEndPointClosed [ConnectionId] 
    -- | Transport-wide fatal error
  | ErrorEventTransportFailure  
    -- | Connection to a remote endpoint was lost
  | ErrorEventConnectionLost EndPointAddress [ConnectionId] 
  deriving Show
