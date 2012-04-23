-- | Utility functions for TCP sockets 
module Network.Transport.Internal.TCP ( forkServer
                                      , sendWithLength
                                      , recvWithLength
                                      , recvExact 
                                      ) where

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
                                     )
import qualified Network.Socket.ByteString as NBS (sendMany, recv)
import Control.Concurrent (forkIO, ThreadId)
import Control.Monad (mzero)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Maybe (MaybeT)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.Int (Int32)

-- | Start a server at the specified address
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

-- | Send a bunch of bytestrings prepended with their length
sendWithLength :: N.Socket           -- ^ Socket to send on
               -> Maybe ByteString   -- ^ Optional header to send before the length
               -> [ByteString]       -- ^ Payload
               -> IO ()
sendWithLength sock header payload = do
  lengthBs <- encodeInt32 (fromIntegral . sum . map BS.length $ payload)
  let msg = maybe id (:) header $ lengthBs : payload
  NBS.sendMany sock msg 

-- | Read a length and then a payload of that length
recvWithLength :: N.Socket -> MaybeT IO [ByteString]
recvWithLength sock = do
  msgLengthBs <- recvExact sock 4
  decodeInt32 (BS.concat msgLengthBs) >>= recvExact sock

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
