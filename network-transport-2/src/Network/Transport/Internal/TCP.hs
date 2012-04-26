-- | Utility functions for TCP sockets 
module Network.Transport.Internal.TCP ( forkServer
                                      , recvWithLength
                                      , recvExact 
                                      , recvInt32
                                      , sendMany
                                      ) where

import Prelude hiding (catch)
import Network.Transport.Internal (decodeInt32)
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
                                     )
import qualified Network.Socket.ByteString as NBS (recv, sendMany)
import Control.Concurrent (forkIO, ThreadId)
import Control.Monad (mzero, MonadPlus, liftM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Error (MonadError)
import Control.Exception (catch, IOException)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null, empty)
import Data.Int (Int32)

-- | Start a server at the specified address
forkServer :: (MonadIO m, MonadError IOException m) 
           => N.HostName -> N.ServiceName -> (N.Socket -> IO ()) -> m ThreadId
forkServer host port server = liftIO $ do 
  -- Resolve the specified address. By specification, getAddrInfo will never
  -- return an empty list (but will throw an exception instead) and will return
  -- the "best" address first, whatever that means
  addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
  sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
  N.setSocketOption sock N.ReuseAddr 1
  N.bindSocket sock (N.addrAddress addr)
  N.listen sock 5
  forkIO $ server sock

-- | Lifted version of 'Network.Socket.ByteString.sendMany'
sendMany :: (MonadIO m) => N.Socket -> [ByteString] -> m ()
sendMany sock msg = liftIO $ NBS.sendMany sock msg

-- | Read a length and then a payload of that length
recvWithLength :: (MonadIO m, MonadPlus m) => N.Socket -> m [ByteString]
recvWithLength sock = recvInt32 sock >>= recvExact sock

-- | Receive a 32-bit integer
recvInt32 :: (Enum a, MonadIO m, MonadPlus m) => N.Socket -> m a 
recvInt32 sock = do
  mi <- liftM (decodeInt32 . BS.concat) $ recvExact sock 4 
  case mi of
    Nothing -> mzero
    Just i  -> return i

-- | Read an exact number of bytes from a socket
--
-- Fails if the socket closes prematurely or the length is non-positive
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
