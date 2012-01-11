module Network.Transport.TCP
  ( mkTransport
  , TCPConfig (..)
  ) where

import Network.Transport

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Monad (forever, unless)
import Data.ByteString.Char8 (ByteString)
import Data.IntMap (IntMap)
import Data.Word
import Network.Socket
import Safe

import qualified Data.ByteString.Char8 as BS
import qualified Data.IntMap as IntMap
import qualified Network.Socket as N
import qualified Network.Socket.ByteString as NBS

type Chans   = MVar (Int, IntMap (Chan ByteString))
type ChanId  = Int

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
    , newMulticastWith = undefined
    , deserialize = \bs ->
        case readMay . BS.unpack $ bs of
          Nothing                      -> error "deserialize: cannot parse"
          Just (host, service, chanId) -> Just $ mkSourceAddr host service chanId
    }

  where
    mkSourceAddr :: HostName -> ServiceName -> ChanId -> SourceAddr
    mkSourceAddr host service chanId = SourceAddr
      { connectWith = \_ -> mkSourceEnd host service chanId
      , serialize   = BS.pack . show $ (host, service, chanId)
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
      NBS.sendAll sock $ BS.pack . show $ chanId
      return $ SourceEnd
        { Network.Transport.send = \bss -> NBS.sendMany sock bss
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
      bs <- NBS.recv clientSock 4096
      case BS.readInt bs of
        Nothing            -> error "procConnections: cannot parse chanId"
        Just (chanId, bs') -> do
          -- lookup the channel
          (_, chanMap) <- readMVar chans
          case IntMap.lookup chanId chanMap of
            Nothing   -> error "procConnections: cannot find chanId"
            Just chan -> forkIO $ do
              unless (BS.null bs') $ writeChan chan bs'
              procMessages chan clientSock

    procMessages :: Chan ByteString -> Socket -> IO ()
    procMessages chan sock = forever $ do
      bs <- NBS.recv sock 4096
      writeChan chan bs
