module Network.Transport
  ( Transport (..)
  , SendAddr (..)
  , SendEnd (..)
  , ReceiveEnd (..)
  , Hints (..)
  , defaultHints
  , SendHints (..)
  , defaultSendHints
  , newConnection
  , newMulticast
  , connect
  ) where

import Data.ByteString.Char8 (ByteString)

------------------------
-- Transport interface
--

-- Buffer size
-- Sending: eager or buffered
-- Big record of defaults
data Hints     = Hints
data SendHints = SendHints

data Transport = Transport
  { newConnectionWith :: Hints -> IO (SendAddr, ReceiveEnd)
  , newMulticastWith  :: Hints -> IO (MulticastSendEnd, MulticastReceiveAddr)
  , deserialize       :: ByteString -> Maybe SendAddr
  }

newConnection :: Transport -> IO (SendAddr, ReceiveEnd)
newConnection transport = newConnectionWith transport defaultHints

newMulticast :: Transport -> IO (MulticastSendEnd, MulticastReceiveAddr)
newMulticast transport = newMulticastWith transport defaultHints

defaultHints :: Hints
defaultHints =  Hints

data SendAddr = SendAddr
  { connectWith :: SendHints -> IO SendEnd
  , serialize   :: ByteString
  }

connect :: SendAddr -> IO SendEnd
connect sendAddr = connectWith sendAddr defaultSendHints

defaultSendHints :: SendHints
defaultSendHints = SendHints

-- Send and receive are vectored
data SendEnd = SendEnd
  { send       :: [ByteString] -> IO ()
  -- , sendAddress      :: SendAddr
  }

newtype ReceiveEnd = ReceiveEnd
  { receive       :: IO [ByteString]
  -- , receiveAddress :: SendAddr
  }

data MulticastSendEnd = MulticastSendEnd
  { multicastSend :: ByteString -> IO ()
  }

data MulticastReceiveAddr = MulticastReceiveAddr
  { multicastConnect :: IO MulticastReceiveEnd
  }

data MulticastReceiveEnd = MulticastReceiveEnd
  { multicastReceive :: IO ByteString
  }

-- data UnorderedSendEnd  -- this is reliable
-- data UnreliableSendEnd -- this is also unordered
--
-- multicast is alwaysw unordered and unreliable

-- TODO:
-- * Multicast
--   * Dual of the Transport: one to many, rather than many to one
--   * Optional: not supported by all transports
-- * Different transport types
--   * Unreliable
--   * Unordered
-- * Send / receive should be vectored

