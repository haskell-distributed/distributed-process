module Network.Transport.QUIC.Internal.TransportState (
    TransportState (eventQueue, innerTransportState),
    EndpointId,
    InnerTransportState (..),
    withTransportState,
    newTransportState,
    registerEndpoint,
) where

import Control.Concurrent (MVar, modifyMVar, newMVar)
import Control.Concurrent.STM.TQueue (TQueue, newTQueueIO)
import Data.Binary (Word32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Network.Transport (EndPoint, Event)

type EndpointId = Word32

data TransportState
    = -- TODO: keep an integer in the state to only assign monotonically
    -- increasing EndpointIds.
    --
    -- This prevents the issue where a remove endpoint sends a message to endpoint ID N. Between
    -- the message being sent and being received, endpoint ID N closes, and a new endpoint
    -- is created, now identified also as N
    --
    -- Alternatively, we could assign endpoint IDs based on a monotonic clock
    TransportState
    { eventQueue :: TQueue Event
    , innerTransportState :: MVar InnerTransportState
    }

data InnerTransportState = InnerTransportState
    { _nextEndpointId :: EndpointId
    , _endpointMap :: Map Word32 EndPoint
    }

withTransportState :: TransportState -> (InnerTransportState -> IO (InnerTransportState, b)) -> IO b
withTransportState (TransportState _ ends) = modifyMVar ends

newTransportState :: IO TransportState
newTransportState =
    TransportState
        <$> newTQueueIO
        <*> newMVar (InnerTransportState 1 mempty)

registerEndpoint :: TransportState -> EndPoint -> IO EndpointId
registerEndpoint ts endpoint =
    withTransportState
        ts
        ( \(InnerTransportState nextId mp) -> do
            pure
                ( InnerTransportState
                    (nextId + 1)
                    (Map.insert nextId endpoint mp)
                , nextId
                )
        )
