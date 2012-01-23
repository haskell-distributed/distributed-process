module Network.Transport.TCP
  ( mkTransport
  , TCPConfig (..)
  ) where

import Network.Transport

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Monad (forever, unless)
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.IntMap (IntMap)
import Data.Int
import Network.Socket
import Safe

import qualified Data.Binary as B
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.IntMap as IntMap
import qualified Network.Socket as N
import qualified Network.Socket.ByteString.Lazy as NBS

type ChanId = Int
type Chans  = MVar (ChanId, IntMap (Chan ByteString))

-- | This deals with several different configuration properties:
--   * Buffer size, specified in Hints
--   * LAN/WAN, since we can inspect the addresses
-- Note that HostName could be an IP address, and ServiceName could be
-- a port number
data TCPConfig = TCPConfig Hints HostName ServiceName

-- | This creates a TCP connection between a server and a number of
-- clients. Behind the scenes, the server hostname is passed as the SourceAddr
-- and when a connection is made, messages sent down the SourceEnd go
-- via a socket made for the client that connected.
-- Messages are all queued using an unbounded Chan.
mkTransport :: TCPConfig -> IO Transport
mkTransport (TCPConfig _hints host service) = withSocketsDo $ do
  channels <- newMVar (0, IntMap.empty)
  serverAddrs <- getAddrInfo
    (Just (N.defaultHints { addrFlags = [AI_PASSIVE] }))
    Nothing
    (Just service)
  let serverAddr = case serverAddrs of
                     [] -> error "mkTransport: getAddrInfo returned []"
                     as -> head as
  sock <- socket (addrFamily serverAddr) Stream defaultProtocol
  bindSocket sock (addrAddress serverAddr)
  listen sock 5
  forkIO $ procConnections channels sock

  return Transport
    { newConnectionWith = \_ -> do
        (chanId, chanMap) <- takeMVar channels
        chan <- newChan
        putMVar channels (chanId + 1, IntMap.insert chanId chan chanMap)
        return (mkSourceAddr host service chanId, mkTargetEnd chan)
    , newMulticastWith = error "newMulticastWith: not defined"
    , deserialize = \bs ->
        let (host, service, chanId) = B.decode bs in
        Just $ mkSourceAddr host service chanId
    }

  where
    mkSourceAddr :: HostName -> ServiceName -> ChanId -> SourceAddr
    mkSourceAddr host service chanId = SourceAddr
      { connectWith = \_ -> mkSourceEnd host service chanId
      , serialize   = B.encode (host, service, chanId)
      }

    mkSourceEnd :: HostName -> ServiceName -> ChanId -> IO SourceEnd
    mkSourceEnd host service chanId = withSocketsDo $ do
      serverAddrs <- getAddrInfo Nothing (Just host) (Just service)
      let serverAddr = case serverAddrs of
                         [] -> error "mkSourceEnd: getAddrInfo returned []"
                         as -> head as
      sock <- socket (addrFamily serverAddr) Stream defaultProtocol
      setSocketOption sock ReuseAddr 1
      N.connect sock (addrAddress serverAddr)
      NBS.sendAll sock $ B.encode (fromIntegral chanId :: Int64)
      return SourceEnd
        { Network.Transport.send = \bs -> do
            let size = fromIntegral (sum . map BS.length $ bs) :: Int64
            NBS.sendAll sock (B.encode size)
            mapM_ (NBS.sendAll sock) bs
        }

    mkTargetEnd :: Chan ByteString -> TargetEnd
    mkTargetEnd chan = TargetEnd
      { -- for now we will implement this as a Chan
        receive = do
          bs <- readChan chan
          return [bs]
      }

    procConnections :: Chans -> Socket -> IO ()
    procConnections chans sock = forever $ do
      (clientSock, _clientAddr) <- accept sock
      -- decode the first message to find the correct chanId
      bs <- recvExact clientSock 8
      let chanId = fromIntegral (B.decode bs :: Int64)
      (_, chanMap) <- readMVar chans
      case IntMap.lookup chanId chanMap of
        Nothing   -> error "procConnections: cannot find chanId"
        Just chan -> forkIO $ procMessages chan clientSock

    -- This function first extracts a header of type Int64, which determines
    -- the size of the ByteString that follows. The ByteString is then
    -- extracted from the socket, and then written to the Chan only when
    -- complete.
    procMessages :: Chan ByteString -> Socket -> IO ()
    procMessages chan sock = forever $ do
      sizeBS <- recvExact sock 8
      let size = B.decode sizeBS
      bs <- recvExact sock size
      writeChan chan bs

-- The result of `recvExact sock n` is a `ByteString` whose length is exactly
-- `n`. No more bytes than necessary are read from the socket.
-- NB: This uses Network.Socket.ByteString.recv, which may *discard*
-- superfluous input depending on the socket type.
recvExact :: Socket -> Int64 -> IO ByteString
recvExact sock n = do
  bs <- NBS.recv sock n
  let remainder = n  - BS.length bs
  if remainder > 0
    then do
      bs' <- recvExact sock remainder
      return (BS.append bs bs')
    else
      return bs

