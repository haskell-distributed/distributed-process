module Network.Transport.QUIC (
    createTransport,
    QUICAddr (..),
) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (
    TQueue,
    newTQueueIO,
    readTQueue,
    writeTQueue,
 )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Set (Set)
import Data.Set qualified as Set
import Network.QUIC qualified as QUIC
import Network.QUIC.Server (defaultServerConfig)
import Network.QUIC.Server qualified as QUIC.Server
import Network.Transport (ConnectionId, EndPoint (..), EndPointAddress (EndPointAddress), Event (..), NewEndPointErrorCode, Transport (..), TransportError (..))

import Control.Concurrent (ThreadId, killThread, myThreadId)
import Control.Exception (bracket)
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.IORef (IORef, newIORef, readIORef)
import GHC.IORef (atomicModifyIORef'_)
import Network.Socket (HostName, ServiceName)

{- | Create a new Transport.

Only a single transport should be created per Haskell process
(threads can, and should, create their own endpoints though).
-}
createTransport :: QUICAddr -> IO Transport
createTransport quicAddr = do
    pure $ Transport (newEndpoint quicAddr) closeQUICTransport

data QUICAddr = QUICAddr
    { quicBindHost :: !HostName
    , quicBindPort :: !ServiceName
    }

newEndpoint :: QUICAddr -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
newEndpoint quicAddr = do
    eventQueue <- newTQueueIO

    state <- EndpointState <$> newIORef mempty

    QUIC.Server.run
        defaultServerConfig
        ( withQUICStream $
            -- TODO: create a bidirectional stream
            -- which can be re-used for sending
            \stream ->
                -- We register which threads are actively receiving or sending
                -- data such that we can cleanly stop
                withThreadRegistered state $ do
                    -- TODO: how to ensure positivity of ConnectionId? QUIC StreamID should be a 62 bit integer,
                    -- so there's room to make it a positive 64 bit integer (ConnectionId ~ Word64)
                    let connId = fromIntegral (QUIC.streamId stream)
                    receiveLoop connId stream eventQueue
        )

    pure . Right $
        EndPoint
            (atomically (readTQueue eventQueue))
            (encodeQUICAddr quicAddr)
            _
            _
            _
            (stopAllThreads state)
  where
    receiveLoop ::
        ConnectionId ->
        QUIC.Stream ->
        TQueue Event ->
        IO ()
    receiveLoop connId stream eventQueue = do
        incoming <- QUIC.recvStream stream 1024 -- TODO: variable length?
        -- TODO: check some state whether we should stop all connections
        if BS.null incoming
            then do
                atomically (writeTQueue eventQueue (ConnectionClosed connId))
            else do
                atomically (writeTQueue eventQueue (Received connId [incoming]))
                receiveLoop connId stream eventQueue

    withQUICStream :: (QUIC.Stream -> IO a) -> QUIC.Connection -> IO a
    withQUICStream f conn =
        bracket
            (QUIC.acceptStream conn)
            (\stream -> QUIC.closeStream stream >> QUIC.Server.stop conn)
            f

    encodeQUICAddr :: QUICAddr -> EndPointAddress
    encodeQUICAddr (QUICAddr host port) = EndPointAddress (BS8.pack $ host <> ":" <> port)

closeQUICTransport :: IO ()
closeQUICTransport = pure ()

{- | We keep track of all threads actively listening on QUIC streams
so that we can cleanly stop these threads when closing the endpoint.

See 'withThreadRegistered' for a combinator which automatically keeps
track of these threads
-}
newtype EndpointState = EndpointState
    { threads :: IORef (Set ThreadId)
    }

withThreadRegistered :: EndpointState -> IO a -> IO a
withThreadRegistered state f =
    bracket
        registerThread
        unregisterThread
        (const f)
  where
    registerThread =
        myThreadId
            >>= \tid ->
                atomicModifyIORef'_ (threads state) (Set.insert tid)
                    $> tid

    unregisterThread tid =
        atomicModifyIORef'_ (threads state) (Set.insert tid)

stopAllThreads :: EndpointState -> IO ()
stopAllThreads (EndpointState tds) =
    readIORef tds >>= traverse_ killThread