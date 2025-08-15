module Network.Transport.QUIC.EndpointState (
    EndpointState,
    newConnection,
) where

import Data.Map.Strict (Map)
import Network.QUIC (Stream, StreamId)
import Network.QUIC qualified as QUIC
import Network.Transport (ConnectionId)

import Data.Map.Strict qualified as Map

newtype EndpointState = EndpointState
    { streamIds :: Map StreamId ConnectionId
    , streams   :: Map 
    }

newConnection :: Stream -> EndpointState -> EndpointState
newConnection stream (EndpointState sids) =
    EndpointState
        ( Map.insert
            (QUIC.streamId stream)
            -- TODO: how to ensure positivity? QUIC StreamID should be a 62 bit integer,
            -- so there's room to make it a positive 64 bit integer (ConnectionId ~ Word64)
            (fromIntegral $ QUIC.streamId stream)
            sids
        )

lookupConnectionId :: EndpointState -> ConnectionId