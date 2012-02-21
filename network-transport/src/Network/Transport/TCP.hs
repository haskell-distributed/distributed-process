module Network.Transport.TCP
  ( mkTransport
  , TCPConfig (..)
  ) where

import Network.Transport

import Control.Concurrent (forkIO, ThreadId, killThread, myThreadId)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Exception (SomeException, IOException, AsyncException(ThreadKilled), 
			  fromException, throwTo, throw, catch, handle)
import Control.Monad (forever, forM_)
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.IntMap (IntMap)
import Data.Int
import Data.Word
import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import Safe
import System.IO (stderr, hPutStrLn)

import qualified Data.Binary as B
import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.IntMap as IntMap
import qualified Network.Socket as N
import qualified Network.Socket.ByteString.Lazy as NBS

type ChanId  = Int
type Chans   = MVar (ChanId, IntMap (Chan [ByteString], [(ThreadId, Socket)]))

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
  threadId <- forkWithExceptions forkIO "Connection Listener" $ 
	      procConnections chans sock

  return Transport
    { newConnectionWith = {-# SCC "newConnectionWith" #-}\_ -> do
        (chanId, chanMap) <- takeMVar chans
        chan <- newChan
        putMVar chans (chanId + 1, IntMap.insert chanId (chan, []) chanMap)
        return (mkSourceAddr host service chanId, mkTargetEnd chans chanId chan)
    , newMulticastWith = error "newMulticastWith: not defined"
    , deserialize = {-# SCC "deserialize" #-} \bs ->
        let (host, service, chanId) = B.decode bs in
        Just $ mkSourceAddr host service chanId
    , closeTransport = {-# SCC "closeTransport" #-} do
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

mkSourceAddr :: HostName -> ServiceName -> ChanId -> SourceAddr
mkSourceAddr host service chanId = SourceAddr
  { connectWith = {-# SCC "connectWith" #-} \_ -> mkSourceEnd host service chanId
  , serialize   = {-# SCC "serialize" #-} B.encode (host, service, chanId)
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
    { send = {-# SCC "send" #-} \bss -> do
        let size = fromIntegral (sum . map BS.length $ bss) :: Int64
        if size < 255
          then
            NBS.sendAll sock (B.encode (fromIntegral size :: Word8))
          else do
            NBS.sendAll sock (B.encode (255 :: Word8))
            NBS.sendAll sock (B.encode size)
        mapM_ (NBS.sendAll sock) bss
    , closeSourceEnd = {-# SCC "closeSourceEnd" #-} sClose sock
    }

mkTargetEnd :: Chans -> ChanId -> Chan [ByteString] -> TargetEnd
mkTargetEnd chans chanId chan = TargetEnd
  { -- for now we will implement this as a Chan
    receive = {-# SCC "receive" #-} readChan chan
  , closeTargetEnd = {-# SCC "closeTargetEnd" #-} do
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

-- | This function waits for inbound connections. If a connection fails
-- for some reason, an error is raised.
procConnections :: Chans -> Socket -> IO ()
procConnections chans sock = forever $ do
  (clientSock, _clientAddr) <- accept sock
  -- decode the first message to find the correct chanId
  bss <- recvExact clientSock 8
  case bss of
    [] -> error "procConnections: inbound chanId aborted"
    bss  -> do
      let bs = BS.concat bss
      let chanId = fromIntegral (B.decode bs :: Int64)
      (chanId', chanMap) <- takeMVar chans
      case IntMap.lookup chanId chanMap of
        Nothing   -> do
          putMVar chans (chanId', chanMap)
          error "procConnections: cannot find chanId"
        Just (chan, socks) -> do
          threadId <- forkWithExceptions forkIO "Message Listener" $ 
		      procMessages chans chanId chan clientSock
          let chanMap' = IntMap.insert chanId (chan, (threadId, clientSock):socks) chanMap
          putMVar chans (chanId', chanMap')

-- | This function first extracts a header of type Word8, which determines
-- the size of the ByteString that follows. If this size is 0, this indicates
-- that the ByteString is large, so the next value is an Int64, which
-- determines the size of the ByteString that follows. The ByteString is then
-- extracted from the socket, and then written to the Chan only when
-- complete. If either of the first header size is null this indicates the
-- socket has closed.
procMessages :: Chans -> ChanId -> Chan [ByteString] -> Socket -> IO ()
procMessages chans chanId chan sock = do
  sizeBSs <- recvExact sock 1
  case sizeBSs of
    []   -> closeSocket
    [onebyte] -> do
      let size = fromIntegral (B.decode onebyte :: Word8)
      if size == 255
        then do
          sizeBSs' <- recvExact sock 8
          case sizeBSs' of
            [] -> closeSocket
            _  -> procMessage (B.decode . BS.concat$ sizeBSs' :: Int64)
        else procMessage size
    ls -> error "Shouldn't receive more than one bytestring when expecting a single byte!"
 where
  closeSocket :: IO ()
  closeSocket = do
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
  procMessage :: Int64 -> IO ()
  procMessage size = do
    bss <- recvExact sock size
    case bss of
      [] -> closeSocket
      _  -> do
        writeChan chan bss
        procMessages chans chanId chan sock

-- | The result of `recvExact sock n` is a `[ByteString]` whose concatenation
-- is of length `n`, received from `sock`. No more bytes than necessary are
-- read from the socket.
-- NB: This uses Network.Socket.ByteString.recv, which may *discard*
-- superfluous input depending on the socket type. Also note that
-- if `recv` returns an empty `ByteString` then this means that the socket
-- was closed: in this case, we return an empty list.
-- NB: It may be appropriate to change the return type to
-- IO (Either ByteString ByteString), where `return Left bs` indicates
-- a partial retrieval since the socket was closed, and `return Right bs`
-- indicates success. This hasn't been implemented, since a Transport `receive`
-- represents an atomic receipt of a message.
recvExact :: Socket -> Int64 -> IO [ByteString]
recvExact sock n = 
   interceptAllExn "recvExact" $ 
   go [] sock n
 where
  go :: [ByteString] -> Socket -> Int64 -> IO [ByteString]
  go bss _    0 = return (reverse bss)
  go bss sock n = do
    bs <- NBS.recv sock n
    if BS.null bs
      then return []
      else go (bs:bss) sock (n - BS.length bs)


interceptAllExn msg = 
   Control.Exception.handle $ \ e -> 
     case fromException e of 
       Just ThreadKilled -> throw e
       Nothing -> do 
	 BSS.hPutStrLn stderr $ BSS.pack$  "Exception inside "++msg++": "++show e
	 throw e
--	 throw (e :: SomeException)

forkWithExceptions :: (IO () -> IO ThreadId) -> String -> IO () -> IO ThreadId
forkWithExceptions forkit descr action = do 
   parent <- myThreadId
   forkit $ 
      Control.Exception.catch action
	 (\ e -> do
          case fromException e of 
            Just ThreadKilled -> 
--    	      BSS.hPutStrLn stderr $ BSS.pack$ "Note: Child thread killed: "++descr
              return ()
	    _ -> do
	      BSS.hPutStrLn stderr $ BSS.pack$ "Exception inside child thread "++descr++": "++show e
	      throwTo parent (e::SomeException)
	 )

