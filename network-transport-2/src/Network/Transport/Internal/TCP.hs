-- | Utility functions for TCP sockets 
module Network.Transport.Internal.TCP ( forkServer
                                      , connectTo
                                      , sendWithLength
                                      , recvWithLength
                                      , sendMany
                                      , recvExact 
                                      ) where

import Prelude hiding (catch)
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
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
import Control.Monad (mzero)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Maybe (MaybeT(MaybeT))
import Control.Exception (catch, IOException)
import Control.Applicative ((<$>), pure)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.Int (Int32)

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
connectTo :: N.HostName -> N.ServiceName -> MaybeT IO N.Socket
connectTo host port = liftIO $ do
  addr:_ <- N.getAddrInfo Nothing (Just host) (Just port) 
  sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
  N.setSocketOption sock N.ReuseAddr 1
  N.connect sock (N.addrAddress addr) 
  return sock

-- | Send a bunch of bytestrings prepended with their length
sendWithLength :: N.Socket           -- ^ Socket to send on
               -> Maybe ByteString   -- ^ Optional header to send before the length
               -> [ByteString]       -- ^ Payload
               -> MaybeT IO ()
sendWithLength sock header payload = do
  lengthBs <- liftIO $ encodeInt32 (fromIntegral . sum . map BS.length $ payload)
  let msg = maybe id (:) header $ lengthBs : payload
  sendMany sock msg 

-- | Read a length and then a payload of that length
recvWithLength :: N.Socket -> MaybeT IO [ByteString]
recvWithLength sock = do
  msgLengthBs <- recvExact sock 4
  decodeInt32 (BS.concat msgLengthBs) >>= recvExact sock

-- | Wrapper around 'Network.Socket.ByteString.sendMany'
-- 
-- Returns Nothing when an I/O exception is raised during the send
sendMany :: N.Socket -> [ByteString] -> MaybeT IO ()
sendMany sock msg = MaybeT $ catch (pure <$> NBS.sendMany sock msg) (handleIOException) 
  where
    handleIOException :: IOException -> IO (Maybe ())
    handleIOException _ = return mzero 

-- | Read an exact number of bytes from a socket
--
-- Returns 'Nothing' if the socket closes prematurely or the length is non-positive
recvExact :: N.Socket                -- ^ Socket to read from 
          -> Int32                   -- ^ Number of bytes to read
          -> MaybeT IO [ByteString]
recvExact _ len | len <= 0 = mzero
recvExact sock len = do
    (socketClosed, input) <- liftIO $ go [] len
    if socketClosed then mzero else return input
  where
    -- Returns input read and whether the socket closed prematurely
    go :: [ByteString] -> Int32 -> IO (Bool, [ByteString])
    go acc 0 = return (False, reverse acc)
    go acc l = do
      bs <- NBS.recv sock (fromIntegral l `min` 4096)
      if BS.null bs 
        then return (True, reverse acc)
        else go (bs : acc) (l - (fromIntegral $ BS.length bs))
