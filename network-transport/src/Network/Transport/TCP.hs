module Network.Transport.TCP
  ( mkTransport
  , TCPConfig (..)
  ) where

import Network.Transport

import Control.Concurrent (forkIO, ThreadId, killThread)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Monad (forever, forM_)
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.IntMap (IntMap)
import Data.Int
import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import Safe

import qualified Data.Binary as B
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.IntMap as IntMap
import qualified Network.Socket as N
import qualified Network.Socket.ByteString.Lazy as NBS

import Debug.Trace

type ChanId  = Int
type Chans   = MVar (ChanId, IntMap (Chan ByteString, [(ThreadId, Socket)]))

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
  chans <- newMVar (0, IntMap.empty)
  serverAddrs <- getAddrInfo
    (Just (N.defaultHints { addrFlags = [AI_PASSIVE] }))
    Nothing
    (Just service)
  let serverAddr = case serverAddrs of
                     [] -> error "mkTransport: getAddrInfo returned []"
                     as -> head as
  sock <- socket (addrFamily serverAddr) Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bindSocket sock (addrAddress serverAddr)
  listen sock 5
  threadId <- forkIO $ procConnections chans sock

  return Transport
    { newConnectionWith = \_ -> do
        (chanId, chanMap) <- takeMVar chans
        chan <- newChan
        putMVar chans (chanId + 1, IntMap.insert chanId (chan, []) chanMap)
        return (mkSourceAddr host service chanId, mkTargetEnd chans chanId chan)
    , newMulticastWith = error "newMulticastWith: not defined"
    , deserialize = \bs ->
        let (host, service, chanId) = B.decode bs in
        Just $ mkSourceAddr host service chanId
    , closeTransport = do
        -- Kill the transport channel process
        killThread threadId
        sClose sock
        -- Kill all target end processes
        (chanId, chanMap) <- takeMVar chans
        forM_ (IntMap.elems chanMap) (\(chan, socks) ->
          forM_ socks (\(threadId', sock') -> do
            killThread threadId'
            sClose sock'))
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
        { send = \bss -> do
            let size = fromIntegral (sum . map BS.length $ bss) :: Int64
            NBS.sendAll sock (B.encode size)
            mapM_ (NBS.sendAll sock) bss
        , closeSourceEnd = sClose sock
        }

    mkTargetEnd :: Chans -> ChanId -> Chan ByteString -> TargetEnd
    mkTargetEnd chans chanId chan = TargetEnd
      { -- for now we will implement this as a Chan
        receive = do
          bs <- readChan chan
          return [bs]
      , closeTargetEnd = do
          (chanId', chanMap) <- takeMVar chans
          case IntMap.lookup chanId chanMap of
            Nothing         -> putMVar chans (chanId', chanMap)
            Just (_, socks) -> do
              forM_ socks $ \(threadId, sock) -> do
                killThread threadId
                sClose sock
              let chanMap' = IntMap.delete chanId chanMap
              putMVar chans (chanId', chanMap')
      }

    procConnections :: Chans -> Socket -> IO ()
    procConnections chans sock = forever $ do
      (clientSock, _clientAddr) <- accept sock
      -- decode the first message to find the correct chanId
      bs <- recvExact clientSock 8
      let chanId = fromIntegral (B.decode bs :: Int64)
      (chanId', chanMap) <- takeMVar chans
      case IntMap.lookup chanId chanMap of
        Nothing   -> do
          putMVar chans (chanId', chanMap)
          error "procConnections: cannot find chanId"
        Just (chan, socks) -> do
          threadId <- forkIO $ procMessages chans chanId chan clientSock
          let chanMap' = IntMap.insert chanId (chan, (threadId, clientSock):socks) chanMap
          putMVar chans (chanId', chanMap')

    -- This function first extracts a header of type Int64, which determines
    -- the size of the ByteString that follows. The ByteString is then
    -- extracted from the socket, and then written to the Chan only when
    -- complete. A length of -1 indicates that the socket has finished
    -- communicating.
    procMessages :: Chans -> ChanId -> Chan ByteString -> Socket -> IO ()
    procMessages chans chanId chan sock = do
      sizeBS <- recvExact sock 8
      let size = B.decode sizeBS
      if size == -1
        then do
          (chanId', chanMap) <- takeMVar chans
          case IntMap.lookup chanId chanMap of
            Nothing            -> do
              putMVar chans (chanId', chanMap)
              error "procMessages: chanId not found."
            Just (chan, socks) -> do
              let socks'   = filter ((/= sock) . snd) socks
              let chanMap' = IntMap.insert chanId (chan, socks') chanMap
              putMVar chans (chanId', chanMap')
          sClose sock
        else do
          bs <- recvExact sock size
          writeChan chan bs
          procMessages chans chanId chan sock

-- | The result of `recvExact sock n` is a `ByteString` of length `n`, received
-- from `sock`. No more bytes than necessary are read from the socket.
-- NB: This uses Network.Socket.ByteString.recv, which may *discard*
-- superfluous input depending on the socket type.
recvExact :: Socket -> Int64 -> IO ByteString
recvExact sock n = go BS.empty sock n
 where
  go bs sock 0 = return bs
  go bs sock n = do
    bs' <- NBS.recv sock n
    go (BS.append bs bs') sock (n - BS.length bs')
