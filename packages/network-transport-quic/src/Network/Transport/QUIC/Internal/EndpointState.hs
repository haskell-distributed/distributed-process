module Network.Transport.QUIC.Internal.EndpointState (
    EndpointState,
    newEndpointState,
    registerStream,
    deregisterStream,
) where

import Control.Monad (void)
import Data.Function ((&))
import Data.IORef (IORef, newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import GHC.IORef (atomicModifyIORef'_)
import Network.QUIC (Stream, streamId)
import Network.Transport (EndPointAddress)

newtype EndpointState = EndpointState (IORef (Map EndPointAddress Stream))

-- \^ Mapping from destination address to stream.
-- A 'Stream' will have two keys since a stream is bidirectional.

newEndpointState :: IO EndpointState
newEndpointState = EndpointState <$> newIORef mempty

registerStream ::
    EndpointState ->
    EndPointAddress ->
    EndPointAddress ->
    Stream ->
    IO ()
registerStream (EndpointState strs) source dest stream =
    void $
        atomicModifyIORef'_
            strs
            ( \st ->
                st
                    & Map.insert source stream
                    & Map.insert dest stream
            )

deregisterStream :: EndpointState -> Stream -> IO ()
deregisterStream (EndpointState strs) stream =
    void $
        atomicModifyIORef'_
            strs
            ( \st ->
                let thisStreamId = streamId stream
                 in Map.filter ((/=) thisStreamId . streamId) st
            )