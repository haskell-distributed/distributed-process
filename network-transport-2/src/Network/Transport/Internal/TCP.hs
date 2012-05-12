-- | Utility functions for TCP sockets 
module Network.Transport.Internal.TCP ( forkServer
                                      , recvWithLength
                                      , recvExact 
                                      , recvInt32
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
                                     , accept
                                     )
import qualified Network.Socket.ByteString as NBS (recv)
import Control.Concurrent (forkIO, ThreadId)
import Control.Monad (mzero, MonadPlus, liftM, forever)
import Control.Exception (SomeException, handle)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.Int (Int32)

-- | Start a server at the specified address.
-- 
-- This sets up a server socket for the specified host and port. Exceptions
-- thrown during setup are not caught.
--
-- Once the socket is created we spawn a new thread which repeatedly accepts
-- incoming connections and executes the given request handler. If any
-- exception occurs the thread terminates and calls the terminationHandler.
-- This exception may occur because of a call to 'N.accept', because the thread
-- was explicitly killed, or because of a synchronous exception thrown by the
-- request handler. Typically, you should avoid the last case by catching any
-- relevant exceptions in the request handler.
--
-- The request handler should spawn threads to handle each individual request
-- or the server will block.
forkServer :: N.HostName               -- ^ Host
           -> N.ServiceName            -- ^ Port 
           -> Int                      -- ^ Backlog (maximum number of queued connections)
           -> (SomeException -> IO ()) -- ^ Termination handler
           -> (N.Socket -> IO ())      -- ^ Request handler 
           -> IO ThreadId
forkServer host port backlog terminationHandler requestHandler = do 
    -- Resolve the specified address. By specification, getAddrInfo will never
    -- return an empty list (but will throw an exception instead) and will return
    -- the "best" address first, whatever that means
    addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
    sock   <- N.socket (N.addrFamily addr) N.Stream N.defaultProtocol
    N.setSocketOption sock N.ReuseAddr 1
    N.bindSocket sock (N.addrAddress addr)
    N.listen sock backlog 
    forkIO . handle terminationHandler . forever $ do 
      (clientSock, _) <- N.accept sock
      requestHandler clientSock
      
-- | Read a length and then a payload of that length
recvWithLength :: N.Socket -> IO [ByteString]
recvWithLength sock = recvInt32 sock >>= recvExact sock

-- | Receive a 32-bit integer
recvInt32 :: Num a => N.Socket -> IO a 
recvInt32 sock = do
  mi <- liftM (decodeInt32 . BS.concat) $ recvExact sock 4 
  case mi of
    Nothing -> mzero
    Just i  -> return i

-- | Read an exact number of bytes from a socket
-- 
-- Throws an I/O exception if the socket closes before the specified
-- number of bytes could be read
recvExact :: N.Socket                -- ^ Socket to read from 
          -> Int32                   -- ^ Number of bytes to read
          -> IO [ByteString]
recvExact _ len | len <= 0 = mzero
recvExact sock len = go [] len
  where
    go :: [ByteString] -> Int32 -> IO [ByteString] 
    go acc 0 = return (reverse acc) 
    go acc l = do
      bs <- NBS.recv sock (fromIntegral l `min` 4096)
      if BS.null bs 
        then fail "Socket closed"
        else go (bs : acc) (l - fromIntegral (BS.length bs))
