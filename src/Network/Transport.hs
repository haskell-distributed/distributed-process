module Network.Transport
  ( Hints (..)
  , ReceiveEnd (..)
  , SendAddr (..)
  , SendEnd (..)
  , SendHints (..)
  , Transport (..)
  , connect
  , defaultHints
  , defaultSendHints
  , newConnection
  , newMulticast
  ) where

import Data.ByteString.Char8 (ByteString)

-- | The `Hints` and `SendHints` provide hints to the underlying transport
-- about the kind of connection that is required. This might include details
-- such as whether the connection is eager or buffered, and the buffer size.
data Hints     = Hints
data SendHints = SendHints

-- | A `Transport` encapsulates the functions required to establish many-to-one
-- and one-to-many connections between clients and servers.
-- The `newConnectionWith` function creates a `ReceiveEnd` that listens to
-- messages sent using the corresponding `SendAddr`. This connection is
-- established using a `Hints` value, which provides information about the
-- connection topology.
-- Each `SendAddr` can be serialised into a `ByteString`, and the `deserialize`
-- function converts this back into a `SendAddr`.
-- Note that these connections provide reliable and ordered messages.
data Transport = Transport
  { newConnectionWith :: Hints -> IO (SendAddr, ReceiveEnd)
  , newMulticastWith  :: Hints -> IO (MulticastSendEnd, MulticastReceiveAddr)
  , deserialize       :: ByteString -> Maybe SendAddr
  }

-- | This is a convenience function that creates a new connection on a transport
-- using the default hints.
newConnection :: Transport -> IO (SendAddr, ReceiveEnd)
newConnection transport = newConnectionWith transport defaultHints

newMulticast :: Transport -> IO (MulticastSendEnd, MulticastReceiveAddr)
newMulticast transport = newMulticastWith transport defaultHints

-- | The default `Hints` for establishing a new transport connection.
defaultHints :: Hints
defaultHints =  Hints

-- | A `SendAddr` is an address that corresponds to a listening `ReceiveEnd`
-- initially created using `newConnection`. A `SendAddr` can be shared between
-- clients by using `serialize`, and passing the resulting `ByteString`.
-- Given a `SendAddr`, the `connectWith` function creates a `SendEnd` which
-- can be used to send messages.
data SendAddr = SendAddr
  { connectWith :: SendHints -> IO SendEnd
  , serialize   :: ByteString
  }

-- | This is a convenience function that connects with a given `SendAddr` using
-- the default hints for sending.
connect :: SendAddr -> IO SendEnd
connect sendAddr = connectWith sendAddr defaultSendHints

-- | The default `SendHints` for establishing a `SendEnd`.
defaultSendHints :: SendHints
defaultSendHints = SendHints

-- | A `SendEnd` provides a `send` function that allows vectored messages
-- to be sent to the corresponding `ReceiveEnd`.
newtype SendEnd = SendEnd
  { send :: [ByteString] -> IO ()
  }

-- | A `ReceiveEnd` provides a `receive` function that allows messages
-- to be received from the corresponding `SendEnd`s.
newtype ReceiveEnd = ReceiveEnd
  { receive :: IO [ByteString]
  }

newtype MulticastSendEnd = MulticastSendEnd
  { multicastSend :: ByteString -> IO ()
  }

newtype MulticastReceiveAddr = MulticastReceiveAddr
  { multicastConnect :: IO MulticastReceiveEnd
  }

newtype MulticastReceiveEnd = MulticastReceiveEnd
  { multicastReceive :: IO ByteString
  }

-- TODO: Other SendEnds that might be of use:
-- data UnorderedSendEnd  -- reliable, unordered
-- data UnreliableSendEnd -- unreliable, unordered

