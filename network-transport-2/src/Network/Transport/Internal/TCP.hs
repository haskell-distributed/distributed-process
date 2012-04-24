-- | Utility functions for TCP sockets 
module Network.Transport.Internal.TCP ( forkServer
                                      , connectTo
                                      , sendWithLength
                                      , recvWithLength
                                      , sendMany
                                      , recvExact 
                                      , recvInt16
                                      , recvInt32
                                      , sendInt16
                                      , sendInt32
                                      ) where

import Prelude hiding (catch)
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
                                  , encodeInt16
                                  , decodeInt16
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , SocketType(Stream)
                                     , SocketOption(ReuseAddr)
                                     , getAddrInfo
                                     , defaultHints
                                     , socket
                                     , bindSocket
                                     , listen
                                     , addrFamily
                                     , addrAddress
                                     , defaultProtocol
                                     , setSocketOption
                                     , connect
                                     )
import qualified Network.Socket.ByteString as NBS (sendMany, recv)
import Control.Concurrent (forkIO, ThreadId)
import Control.Monad (mzero, MonadPlus, unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Exception (catch, IOException)
import Control.Applicative (pure)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null, empty)
import Data.Int (Int16, Int32)

-- | Start a server at the specified address
--
-- TODO: deal with errors
forkServer :: N.HostName -> N.ServiceName -> (N.Socket -> IO ()) -> IO ThreadId 
forkServer host port server = do
  -- Resolve the specified address. By specification, getAddrInfo will never
  -- return an empty list (but will throw an exception instead) and will return
  -- the "best" address first, whatever that means
  addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
  sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
  N.setSocketOption sock N.ReuseAddr 1
  N.bindSocket sock (N.addrAddress addr)
  N.listen sock 5
  forkIO $ server sock

-- | Connect to another host 
-- 
-- TODO: deal with errors
connectTo :: (MonadIO m) => N.HostName -> N.ServiceName -> m N.Socket
connectTo host port = liftIO $ do
  addr:_ <- N.getAddrInfo Nothing (Just host) (Just port) 
  sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
  N.setSocketOption sock N.ReuseAddr 1
  N.connect sock (N.addrAddress addr) 
  return sock

-- | Send a bunch of bytestrings prepended with their length
sendWithLength :: (MonadIO m, MonadPlus m) 
               => N.Socket           -- ^ Socket to send on
               -> Maybe ByteString   -- ^ Optional header to send before the length
               -> [ByteString]       -- ^ Payload
               -> m ()
sendWithLength sock header payload = do
  lengthBs <- liftIO $ encodeInt32 (fromIntegral . sum . map BS.length $ payload)
  let msg = maybe id (:) header $ lengthBs : payload
  sendMany sock msg 

-- | Read a length and then a payload of that length
recvWithLength :: (MonadIO m, MonadPlus m) => N.Socket -> m [ByteString]
recvWithLength sock = do
  msgLengthBs <- recvExact sock 4
  decodeInt32 (BS.concat msgLengthBs) >>= recvExact sock

-- | Wrapper around 'Network.Socket.ByteString.sendMany'
-- 
-- Returns Nothing when an I/O exception is raised during the send
sendMany :: (MonadIO m, MonadPlus m) => N.Socket -> [ByteString] -> m ()
sendMany sock msg = do 
    success <- liftIO $ catch (NBS.sendMany sock msg >> return True) handleIOException 
    unless success mzero
  where
    handleIOException :: IOException -> IO Bool
    handleIOException _ = return False

-- | Read an exact number of bytes from a socket
--
-- Returns 'Nothing' if the socket closes prematurely or the length is non-positive
recvExact :: (MonadIO m, MonadPlus m) 
          => N.Socket                -- ^ Socket to read from 
          -> Int32                   -- ^ Number of bytes to read
          -> m [ByteString]
recvExact _ len | len <= 0 = mzero
recvExact sock len = do
    (socketClosed, input) <- liftIO $ go [] len
    if socketClosed then mzero else return input
  where
    -- Returns input read and whether the socket closed prematurely
    go :: [ByteString] -> Int32 -> IO (Bool, [ByteString])
    go acc 0 = return (False, reverse acc)
    go acc l = do
      bs <- catch (NBS.recv sock (fromIntegral l `min` 4096)) handleIOException
      if BS.null bs 
        then return (True, reverse acc)
        else go (bs : acc) (l - fromIntegral (BS.length bs))
    
    -- We treat an I/O exception the same way as a socket closure
    handleIOException :: IOException -> IO ByteString
    handleIOException _ = return BS.empty 

-- | Receive a 16-bit integer
recvInt16 :: (MonadIO m, MonadPlus m) => N.Socket -> m Int16
recvInt16 sock = recvExact sock 2 >>= decodeInt16 . BS.concat

-- | Receive a 32-bit integer
recvInt32 :: (MonadIO m, MonadPlus m) => N.Socket -> m Int32
recvInt32 sock = recvExact sock 4 >>= decodeInt32 . BS.concat 

-- | Send a 16-bit integer
sendInt16 :: (MonadIO m, MonadPlus m) => N.Socket -> Int16 -> m ()
sendInt16 sock n = encodeInt16 n >>= sendMany sock . pure 

-- | Send a 32-bit integer
sendInt32 :: (MonadIO m, MonadPlus m) => N.Socket -> Int32 -> m ()
sendInt32 sock n = encodeInt32 n >>= sendMany sock . pure 
