{-# LANGUAGE CPP #-}

module Network.Transport.TCP
  ( mkTransport
  , TCPConfig (..)
  ) where

import Network.Transport

import Control.Applicative
import Control.Concurrent (forkIO, ThreadId, killThread, myThreadId)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Exception (SomeException, IOException, AsyncException(ThreadKilled), 
			  fromException, throwTo, throw, catch, handle)
import Control.Monad (forever, forM_)

import qualified Data.ByteString.Internal as BSI

import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap

import Data.Int (Int32)
import qualified Data.Serialize as Ser
import Data.Word (Word8)

import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (sizeOf)

import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import qualified Network.Socket as N

import Text.Printf

import Safe
import System.IO (stderr, hPutStrLn)

#ifndef LAZY
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Network.Socket.ByteString as NBS
sendNBS = NBS.sendMany
encode = Ser.encode
decode = Ser.decode
#else
import Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Network.Socket.ByteString.Lazy as NBS
sendNBS sock = NBS.sendAll sock . BS.concat
encode = Ser.encodeLazy
decode = Ser.decodeLazy
#endif
{-# INLINE encode #-}
{-# INLINE decode #-}
encode :: Ser.Serialize a => a -> ByteString
decode :: Ser.Serialize a => ByteString -> Either String a

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
        let (host, service, chanId) =
              either (\m -> error $ printf "deserialize: %s" m) 
                     id $ decode bs in
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
  , serialize   = {-# SCC "serialize" #-} encode (host, service, chanId)
  }

mkSourceEnd :: HostName -> ServiceName -> ChanId -> IO SourceEnd
mkSourceEnd host service chanId = withSocketsDo $ do
  let err m = error $ printf "mkSourceEnd: %s" m
  serverAddrs <- getAddrInfo Nothing (Just host) (Just service)
  let serverAddr = case serverAddrs of
                     [] -> err "getAddrInfo returned []"
                     as -> head as
  sock <- socket (addrFamily serverAddr) Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  N.connect sock (addrAddress serverAddr)
  NBS.sendAll sock $ encode (fromIntegral chanId :: Int32)
  return SourceEnd
    { send = {-# SCC "send" #-} \bss -> do
        let size = fromIntegral (sum . map BS.length $ bss) :: Int32
            sizeStr | size < 255 = BS.singleton (toEnum $ fromEnum size)
                    | otherwise  = BS.cons (toEnum 255) (encode size)
        sendNBS sock (sizeStr:bss)
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
  let err m = error $ printf "procConnections: %s" m
  (clientSock, _clientAddr) <- accept sock
  -- decode the first message to find the correct chanId
  bss <- recvExact clientSock (fromIntegral $ sizeOf (0 :: Int32))
  case bss of
    Left _ -> err "inbound chanId aborted"
    Right bs -> do
      let chanId = either err fromIntegral (decode bs :: Either String Int32)
      (chanId', chanMap) <- takeMVar chans
      case IntMap.lookup chanId chanMap of
        Nothing   -> do
          putMVar chans (chanId', chanMap)
          err "cannot find chanId"
        Just (chan, socks) -> do
          threadId <- forkWithExceptions forkIO "Message Listener" $ 
		      procMessages chans chanId chan clientSock
          let chanMap' = IntMap.insert chanId (chan, (threadId, clientSock):socks) chanMap
          putMVar chans (chanId', chanMap')

-- | This function first extracts a header of type Word8, which determines
-- the size of the ByteString that follows. If this size is 0, this indicates
-- that the ByteString is large, so the next value is an Int32, which
-- determines the size of the ByteString that follows. The ByteString is then
-- extracted from the socket, and then written to the Chan only when
-- complete. If either of the first header size is null this indicates the
-- socket has closed.
procMessages :: Chans -> ChanId -> Chan [ByteString] -> Socket -> IO ()
procMessages chans chanId chan sock = do
  esizeBS <- recvExact sock 1
  case esizeBS of
    Left _ -> closeSocket
    Right sizeBS -> do
      case decode sizeBS :: Either String Word8 of
        Right 255 -> do
          esizeBS' <- recvExact sock (fromIntegral $ sizeOf (0 :: Int32))
          case esizeBS' of
            Left _ -> closeSocket
            Right sizeBS' -> procMessage $ decode sizeBS'
        esize@(Right _) -> procMessage (fromIntegral <$> esize)
        Left msg -> error msg
 where
  err m = error $ printf "procMessages: %s" m
  closeSocket :: IO ()
  closeSocket = do
    (chanId', chanMap) <- takeMVar chans
    case IntMap.lookup chanId chanMap of
      Nothing            -> do
        putMVar chans (chanId', chanMap)
        err "chanId not found."
      Just (chan, socks) -> do
        let socks'   = filter ((/= sock) . snd) socks
        let chanMap' = IntMap.insert chanId (chan, socks') chanMap
        putMVar chans (chanId', chanMap')
    sClose sock
  procMessage :: Either String Int32 -> IO ()
  procMessage (Left  msg) = err msg
  procMessage (Right size) = do
    ebs <- recvExact sock size
    case ebs of
      Left _ -> closeSocket
      Right bs -> do
        writeChan chan [bs]
        procMessages chans chanId chan sock

-- | The normal result of `recvExact sock n` is `Right ByteString`
-- whose string of length `n`, received from `sock`. If fewer than `n`
-- bytes are read from `sock` before it closes, the result is `Left
-- ByteString` whose string is those bytes that were received. No more
-- bytes than necessary are read from the socket.  NB: This uses
-- Network.Socket.ByteString.recv, which may *discard* superfluous
-- input depending on the socket type.
#ifndef LAZY
recvExact :: Socket -> Int32 -> IO (Either ByteString ByteString)
recvExact sock l = interceptAllExn "recvExact" $ do
  res <- BSI.createAndTrim (fromIntegral l) (go 0)
  case BS.length res of
    n | n == (fromIntegral l) -> return $ Right res
    n                         -> return $ Left res
 where
  go :: Int -> Ptr Word8 -> IO Int
  go n ptr | n == (fromIntegral l) = return n
  go n ptr = do
    (p, off, len) <- BSI.toForeignPtr <$> NBS.recv sock (min (fromIntegral l-n) 4096)
    if len == 0
      then return n
      else withForeignPtr p $ \p -> do
             BSI.memcpy (ptr `plusPtr` n) (p `plusPtr` off) (fromIntegral len)
             go (n+len) ptr 
#else
recvExact :: Socket -> Int32 -> IO (Either ByteString ByteString)
recvExact sock n = 
   interceptAllExn "recvExact" $
   go [] sock n
 where
  go :: [ByteString] -> Socket -> Int32 -> IO (Either ByteString ByteString)
  go bss _    0 = return (Right $ BS.concat (reverse bss))
  go bss sock n = do
    bs <- NBS.recv sock (min (fromIntegral n) 4096)
    if BS.null bs
      then return (Left $ BS.concat (reverse bss))
      else go (bs:bss) sock (n - (fromIntegral $ BS.length bs))
#endif

interceptAllExn msg = 
   Control.Exception.handle $ \ e -> 
     case fromException e of 
       Just ThreadKilled -> throw e
       Nothing -> do 
	 BS.hPutStrLn stderr $ BS.pack$  "Exception inside "++msg++": "++show e
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
	      BS.hPutStrLn stderr $ BS.pack$ "Exception inside child thread "++descr++": "++show e
	      throwTo parent (e::SomeException)
	 )

