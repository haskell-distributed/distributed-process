module Network.Transport.TCP
  ( mkTransport
  ) where

import Network.Transport
import Data.Word

data Address = Address String
type Port    = Word16

-- | This deals with several different configuration properties:
--   * Buffer size, specified in Hints
--   * LAN/WAN, since we can inspect the addresses
data TCPConfig = TCPConfig Hints Port Address Address

mkTransport :: TCPConfig -> IO Transport
mkTransport tcpConfig =
  -- create buffer
  -- allocate listening socket
  -- fork thread on that socket
  return Transport
    { newConnectionWith = undefined
        -- create listening mailbox
        -- send back mailbox details
    , newMulticastWith = undefined
    , deserialize = undefined
    }

