-- | Utility functions for TCP sockets
module Network.Transport.TCP.Internal
  ( forkServer
  , recvWithLength
  , recvExact
  , recvInt32
  , tryCloseSocket
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Network.Transport.Internal (decodeInt32, void, tryIO, forkIOWithUnmask)

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket as N
#else
import qualified Network.Socket as N
#endif
  ( HostName
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
  , sClose
  )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket.ByteString as NBS (recv)
#else
import qualified Network.Socket.ByteString as NBS (recv)
#endif

import Control.Concurrent (ThreadId)
import Control.Monad (forever, when)
import Control.Exception (SomeException, catch, bracketOnError, throwIO, mask_)
import Control.Applicative ((<$>))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.Int (Int32)
import Data.ByteString.Lazy.Internal (smallChunkSize)

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
-- or the server will block. Once a thread has been spawned it will be the
-- responsibility of the new thread to close the socket when an exception
-- occurs.
forkServer :: N.HostName               -- ^ Host
           -> N.ServiceName            -- ^ Port
           -> Int                      -- ^ Backlog (maximum number of queued connections)
           -> Bool                     -- ^ Set ReuseAddr option?
           -> (SomeException -> IO ()) -- ^ Termination handler
           -> (N.Socket -> IO ())      -- ^ Request handler
           -> IO ThreadId
forkServer host port backlog reuseAddr terminationHandler requestHandler = do
    -- Resolve the specified address. By specification, getAddrInfo will never
    -- return an empty list (but will throw an exception instead) and will return
    -- the "best" address first, whatever that means
    addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
    bracketOnError (N.socket (N.addrFamily addr) N.Stream N.defaultProtocol)
                   tryCloseSocket $ \sock -> do
      when reuseAddr $ N.setSocketOption sock N.ReuseAddr 1
      N.bindSocket sock (N.addrAddress addr)
      N.listen sock backlog
      -- We start listening for incoming requests in a separate thread. When
      -- that thread is killed, we close the server socket and the termination
      -- handler. We have to make sure that the exception handler is installed
      -- /before/ any asynchronous exception occurs. So we mask_, then fork
      -- (the child thread inherits the masked state from the parent), then
      -- unmask only inside the catch.
      mask_ $ forkIOWithUnmask $ \unmask ->
        catch (unmask (forever $ acceptRequest sock)) $ \ex -> do
          tryCloseSocket sock
          terminationHandler ex
  where
    acceptRequest :: N.Socket -> IO ()
    acceptRequest sock = bracketOnError (N.accept sock)
                                        (tryCloseSocket . fst)
                                        (requestHandler . fst)

-- | Read a length and then a payload of that length
recvWithLength :: N.Socket -> IO [ByteString]
recvWithLength sock = recvInt32 sock >>= recvExact sock

-- | Receive a 32-bit integer
recvInt32 :: Num a => N.Socket -> IO a
recvInt32 sock = decodeInt32 . BS.concat <$> recvExact sock 4

-- | Close a socket, ignoring I/O exceptions
tryCloseSocket :: N.Socket -> IO ()
tryCloseSocket sock = void . tryIO $
  N.sClose sock

-- | Read an exact number of bytes from a socket
--
-- Throws an I/O exception if the socket closes before the specified
-- number of bytes could be read
recvExact :: N.Socket                -- ^ Socket to read from
          -> Int32                   -- ^ Number of bytes to read
          -> IO [ByteString]
recvExact _ len | len < 0 = throwIO (userError "recvExact: Negative length")
recvExact sock len = go [] len
  where
    go :: [ByteString] -> Int32 -> IO [ByteString]
    go acc 0 = return (reverse acc)
    go acc l = do
      bs <- NBS.recv sock (fromIntegral l `min` smallChunkSize)
      if BS.null bs
        then throwIO (userError "recvExact: Socket closed")
        else go (bs : acc) (l - fromIntegral (BS.length bs))
