-- | Utility functions for TCP sockets
module Network.Transport.TCP.Internal
  ( ControlHeader(..)
  , encodeControlHeader
  , decodeControlHeader
  , ConnectionRequestResponse(..)
  , encodeConnectionRequestResponse
  , decodeConnectionRequestResponse
  , forkServer
  , recvWithLength
  , recvExact
  , recvWord32
  , encodeWord32
  , tryCloseSocket
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Network.Transport.Internal
  ( decodeWord32
  , encodeWord32
  , void
  , tryIO
  , forkIOWithUnmask
  )

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
  , socketPort
  )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket.ByteString as NBS (recv)
#else
import qualified Network.Socket.ByteString as NBS (recv)
#endif

import Control.Concurrent (ThreadId)
import Data.Word (Word32)

import Control.Monad (forever, when)
import Control.Exception (SomeException, catch, bracketOnError, throwIO, mask_)
import Control.Applicative ((<$>), (<*>))
import Data.Word (Word32)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.ByteString.Lazy.Internal (smallChunkSize)

-- | Control headers
data ControlHeader =
    -- | Tell the remote endpoint that we created a new connection
    CreatedNewConnection
    -- | Tell the remote endpoint we will no longer be using a connection
  | CloseConnection
    -- | Request to close the connection (see module description)
  | CloseSocket
    -- | Sent by an endpoint when it is closed.
  | CloseEndPoint
    -- | Message sent to probe a socket
  | ProbeSocket
    -- | Acknowledgement of the ProbeSocket message
  | ProbeSocketAck
  deriving (Show)

decodeControlHeader :: Word32 -> Maybe ControlHeader
decodeControlHeader w32 = case w32 of
  0 -> Just CreatedNewConnection
  1 -> Just CloseConnection
  2 -> Just CloseSocket
  3 -> Just CloseEndPoint
  4 -> Just ProbeSocket
  5 -> Just ProbeSocketAck
  _ -> Nothing

encodeControlHeader :: ControlHeader -> Word32
encodeControlHeader ch = case ch of
  CreatedNewConnection -> 0
  CloseConnection      -> 1
  CloseSocket          -> 2
  CloseEndPoint        -> 3
  ProbeSocket          -> 4
  ProbeSocketAck       -> 5

-- | Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    -- | /B/ accepts the connection
    ConnectionRequestAccepted
    -- | /A/ requested an invalid endpoint
  | ConnectionRequestInvalid
    -- | /A/s request crossed with a request from /B/ (see protocols)
  | ConnectionRequestCrossed
  deriving (Show)

decodeConnectionRequestResponse :: Word32 -> Maybe ConnectionRequestResponse
decodeConnectionRequestResponse w32 = case w32 of
  0 -> Just ConnectionRequestAccepted
  1 -> Just ConnectionRequestInvalid
  2 -> Just ConnectionRequestCrossed
  _ -> Nothing

encodeConnectionRequestResponse :: ConnectionRequestResponse -> Word32
encodeConnectionRequestResponse crr = case crr of
  ConnectionRequestAccepted -> 0
  ConnectionRequestInvalid  -> 1
  ConnectionRequestCrossed  -> 2

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
--
-- The return value includes the port was bound to. This is not always the same
-- port as that given in the argument. For example, binding to port 0 actually
-- binds to a random port, selected by the OS.
forkServer :: N.HostName               -- ^ Host
           -> N.ServiceName            -- ^ Port
           -> Int                      -- ^ Backlog (maximum number of queued connections)
           -> Bool                     -- ^ Set ReuseAddr option?
           -> (SomeException -> IO ()) -- ^ Termination handler
           -> (N.Socket -> IO ())      -- ^ Request handler
           -> IO (N.ServiceName, ThreadId)
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
      (,) <$> fmap show (N.socketPort sock) <*>
        (mask_ $ forkIOWithUnmask $ \unmask ->
          catch (unmask (forever $ acceptRequest sock)) $ \ex -> do
            tryCloseSocket sock
            terminationHandler ex)
  where
    acceptRequest :: N.Socket -> IO ()
    acceptRequest sock = bracketOnError (N.accept sock)
                                        (tryCloseSocket . fst)
                                        (requestHandler . fst)

-- | Read a length and then a payload of that length, subject to an optional
--   limit on the length.
recvWithLength :: Maybe Word32 -> N.Socket -> IO [ByteString]
recvWithLength mlimit sock = case mlimit of
  Nothing -> recvWord32 sock >>= recvExact sock
  Just limit -> do
    length <- recvWord32 sock
    when (length > limit) $
      throwIO (userError "recvWithLength: limit exceeded")
    recvExact sock length

-- | Receive a 32-bit unsigned integer
recvWord32 :: N.Socket -> IO Word32
recvWord32 = fmap (decodeWord32 . BS.concat) . flip recvExact 4

-- | Close a socket, ignoring I/O exceptions.
tryCloseSocket :: N.Socket -> IO ()
tryCloseSocket sock = void . tryIO $
  N.sClose sock

-- | Read an exact number of bytes from a socket
--
-- Throws an I/O exception if the socket closes before the specified
-- number of bytes could be read
recvExact :: N.Socket                -- ^ Socket to read from
          -> Word32                  -- ^ Number of bytes to read
          -> IO [ByteString]
recvExact _ len | len < 0 = throwIO (userError "recvExact: Negative length")
recvExact sock len = go [] len
  where
    go :: [ByteString] -> Word32 -> IO [ByteString]
    go acc 0 = return (reverse acc)
    go acc l = do
      bs <- NBS.recv sock (fromIntegral l `min` smallChunkSize)
      if BS.null bs
        then throwIO (userError "recvExact: Socket closed")
        else go (bs : acc) (l - fromIntegral (BS.length bs))
