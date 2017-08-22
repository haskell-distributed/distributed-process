-- | Multicast utilities
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Control.Distributed.Process.Backend.SimpleLocalnet.Internal.Multicast (initMulticast) where

import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Binary (Binary, decode, encode)
import Data.IORef (IORef, newIORef, readIORef, modifyIORef)
import qualified Data.ByteString as BSS (ByteString, concat)
import qualified Data.ByteString.Lazy as BSL
  ( ByteString
  , empty
  , append
  , fromChunks
  , toChunks
  , length
  , splitAt
  )
import Data.Accessor (Accessor, (^:), (^.), (^=))
import qualified Data.Accessor.Container as DAC (mapDefault)
import Control.Applicative ((<$>))
import Network.Socket (HostName, PortNumber, Socket, SockAddr)
import qualified Network.Socket.ByteString as NBS (recvFrom, sendManyTo)
import Network.Transport.Internal (decodeNum32, encodeEnum32)
import Network.Multicast (multicastSender, multicastReceiver)

--------------------------------------------------------------------------------
-- Top-level API                                                              --
--------------------------------------------------------------------------------

-- | Given a hostname and a port number, initialize the multicast system.
--
-- Note: it is important that you never send messages larger than the maximum
-- message size; if you do, all subsequent communication will probably fail.
--
-- Returns a reader and a writer.
--
-- NOTE: By rights the two functions should be "locally" polymorphic in 'a',
-- but this requires impredicative types.
initMulticast :: forall a. Binary a
              => HostName    -- ^ Multicast IP
              -> PortNumber  -- ^ Port number
              -> Int         -- ^ Maximum message size
              -> IO (IO (a, SockAddr), a -> IO ())
initMulticast host port bufferSize = do
    (sendSock, sendAddr) <- multicastSender host port
    readSock <- multicastReceiver host port
    st <- newIORef Map.empty
    return (recvBinary readSock st bufferSize, writer sendSock sendAddr)
  where
    writer :: forall a. Binary a => Socket -> SockAddr -> a -> IO ()
    writer sock addr val = do
      let bytes = encode val
          len   = encodeEnum32 (BSL.length bytes)
      NBS.sendManyTo sock (len : BSL.toChunks bytes) addr

--------------------------------------------------------------------------------
-- UDP multicast read, dealing with multiple senders                          --
--------------------------------------------------------------------------------

type UDPState = Map SockAddr BSL.ByteString

#if MIN_VERSION_network(2,4,0)
-- network-2.4.0 provides the Ord instance for us
#else
instance Ord SockAddr where
  compare = compare `on` show
#endif

bufferFor :: SockAddr -> Accessor UDPState BSL.ByteString
bufferFor = DAC.mapDefault BSL.empty

bufferAppend :: SockAddr -> BSS.ByteString -> UDPState -> UDPState
bufferAppend addr bytes =
  bufferFor addr ^: flip BSL.append (BSL.fromChunks [bytes])

recvBinary :: Binary a => Socket -> IORef UDPState -> Int -> IO (a, SockAddr)
recvBinary sock st bufferSize = do
  (bytes, addr) <- recvWithLength sock st bufferSize
  return (decode bytes, addr)

recvWithLength :: Socket
               -> IORef UDPState
               -> Int
               -> IO (BSL.ByteString, SockAddr)
recvWithLength sock st bufferSize = do
  (len, addr) <- recvExact sock 4 st bufferSize
  let n = decodeNum32 . BSS.concat . BSL.toChunks $ len
  bytes <- recvExactFrom addr sock n st bufferSize
  return (bytes, addr)

-- Receive all bytes currently in the buffer
recvAll :: Socket -> IORef UDPState -> Int -> IO SockAddr
recvAll sock st bufferSize = do
  (bytes, addr) <- NBS.recvFrom sock bufferSize
  modifyIORef st $ bufferAppend addr bytes
  return addr

recvExact :: Socket
          -> Int
          -> IORef UDPState
          -> Int
          -> IO (BSL.ByteString, SockAddr)
recvExact sock n st bufferSize = do
  addr  <- recvAll sock st bufferSize
  bytes <- recvExactFrom addr sock n st bufferSize
  return (bytes, addr)

recvExactFrom :: SockAddr
              -> Socket
              -> Int
              -> IORef UDPState
              -> Int
              -> IO BSL.ByteString
recvExactFrom addr sock n st bufferSize = go
  where
    go :: IO BSL.ByteString
    go = do
      accAddr <- (^. bufferFor addr) <$> readIORef st
      if BSL.length accAddr >= fromIntegral n
        then do
          let (bytes, accAddr') = BSL.splitAt (fromIntegral n) accAddr
          modifyIORef st $ bufferFor addr ^= accAddr'
          return bytes
        else do
          _ <- recvAll sock st bufferSize
          go
