-- |
-- Module: Network.Transport.InMemory.Debug
--
-- Miscelanteous functions for debug purposes.
module Network.Transport.InMemory.Debug
  ( breakConnection
  ) where

import Control.Concurrent.STM
import Network.Transport
import Network.Transport.InMemory.Internal

-- | Function that simulate failing connection between two endpoints,
-- after calling this function both endpoints will receive ConnectionEventLost
-- message, and all @LocalConnectionValid@ connections will
-- be put into @LocalConnectionFailed@ state.
breakConnection :: TransportInternals
                -> EndPointAddress          -- ^ @From@ connection
                -> EndPointAddress          -- ^ @To@ connection
                -> String                   -- ^ Error message
                -> IO ()
breakConnection (TransportInternals state) from to message =
  atomically $ apiBreakConnection state from to message

