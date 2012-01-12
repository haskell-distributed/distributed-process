module Network.Transport
  ( Hints (..)
  , TargetEnd (..)
  , SourceAddr (..)
  , SourceEnd (..)
  , SourceHints (..)
  , Transport (..)
  , connect
  , defaultHints
  , defaultSourceHints
  , newConnection
  , newMulticast
  ) where

import Data.ByteString.Char8 (ByteString)

-- | The `Hints` and `SourceHints` provide hints to the underlying transport
-- about the kind of connection that is required. This might include details
-- such as whether the connection is eager or buffered, and the buffer size.
data Hints     = Hints
data SourceHints = SourceHints

-- | A `Transport` encapsulates the functions required to establish many-to-one
-- and one-to-many connections between clients and servers.
-- The `newConnectionWith` function creates a `TargetEnd` that listens to
-- messages sent using the corresponding `SourceAddr`. This connection is
-- established using a `Hints` value, which provides information about the
-- connection topology.
-- Each `SourceAddr` can be serialised into a `ByteString`, and the `deserialize`
-- function converts this back into a `SourceAddr`.
-- Note that these connections provide reliable and ordered messages.
data Transport = Transport
  { newConnectionWith :: Hints -> IO (SourceAddr, TargetEnd)
  , newMulticastWith  :: Hints -> IO (MulticastSourceEnd, MulticastTargetAddr)
  , deserialize       :: ByteString -> Maybe SourceAddr
  }

-- | This is a convenience function that creates a new connection on a transport
-- using the default hints.
newConnection :: Transport -> IO (SourceAddr, TargetEnd)
newConnection transport = newConnectionWith transport defaultHints

newMulticast :: Transport -> IO (MulticastSourceEnd, MulticastTargetAddr)
newMulticast transport = newMulticastWith transport defaultHints

-- | The default `Hints` for establishing a new transport connection.
defaultHints :: Hints
defaultHints =  Hints

-- | A `SourceAddr` is an address that corresponds to a listening `TargetEnd`
-- initially created using `newConnection`. A `SourceAddr` can be shared between
-- clients by using `serialize`, and passing the resulting `ByteString`.
-- Given a `SourceAddr`, the `connectWith` function creates a `SourceEnd` which
-- can be used to send messages.
data SourceAddr = SourceAddr
  { connectWith :: SourceHints -> IO SourceEnd
  , serialize   :: ByteString
  }

-- | This is a convenience function that connects with a given `SourceAddr` using
-- the default hints for sending.
connect :: SourceAddr -> IO SourceEnd
connect sourceAddr = connectWith sourceAddr defaultSourceHints

-- | The default `SourceHints` for establishing a `SourceEnd`.
defaultSourceHints :: SourceHints
defaultSourceHints = SourceHints

-- | A `SourceEnd` provides a `send` function that allows vectored messages
-- to be sent to the corresponding `TargetEnd`.
-- The `close` function closes the connection between this source and the target
-- end. Connections between other sources the target end remain unaffected
data SourceEnd = SourceEnd
  { send :: [ByteString] -> IO ()
  , closeSourceEnd :: IO ()
  }

-- | A `TargetEnd` provides a `receive` function that allows messages
-- to be received from the corresponding `SourceEnd`s.
-- The `closeAll` function closes all connections to this target,
-- and all new connections will be refused.
data TargetEnd = TargetEnd
  { receive :: IO [ByteString]
  , closeTargetEnd :: IO ()
  }

newtype MulticastSourceEnd = MulticastSourceEnd
  { multicastSource :: ByteString -> IO ()
  }

newtype MulticastTargetAddr = MulticastTargetAddr
  { multicastConnect :: IO MulticastTargetEnd
  }

newtype MulticastTargetEnd = MulticastTargetEnd
  { multicastReceive :: IO ByteString
  }

-- TODO: Other SourceEnds that might be of use:
-- data UnorderedSourceEnd  -- reliable, unordered
-- data UnreliableSourceEnd -- unreliable, unordered

