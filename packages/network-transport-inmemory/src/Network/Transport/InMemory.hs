-- | In-memory implementation of the Transport API.
module Network.Transport.InMemory
  ( createTransport
  , createTransportExposeInternals
  -- * For testing purposes
  , TransportInternals(..)
  , breakConnection
  ) where

import Network.Transport
import Network.Transport.InMemory.Internal
import Network.Transport.InMemory.Debug

-- | Create a new Transport.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport :: IO Transport
createTransport = fmap fst createTransportExposeInternals

