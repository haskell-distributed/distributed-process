{-# LANGUAGE EmptyDataDecls #-}
module Network.Transport.TCP.Mock.Socket
  ( -- * Types
    HostName
  , ServiceName
  , Socket
  , SocketType(..)
  , SocketOption(..)
  , AddrInfo(..)
  , Family
  , SockAddr
  , ProtocolNumber
  , ShutdownCmd(..)
    -- * Functions
  , getAddrInfo
  , socket
  , bindSocket
  , listen
  , setSocketOption
  , accept
  , sClose
  , connect
  , shutdown
    -- * Constants
  , defaultHints
  , defaultProtocol
  , sOMAXCONN
    -- * Internal API
  , writeSocket
  , readSocket
  , Message(..)
  ) where

import Data.Word (Word8)
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Category ((>>>))
import Control.Concurrent.MVar 
import Control.Concurrent.Chan
import System.IO.Unsafe (unsafePerformIO)
import Data.Accessor (Accessor, accessor, (^=), (^.))
import qualified Data.Accessor.Container as DAC (mapMaybe)

--------------------------------------------------------------------------------
-- Mock state                                                                 --
--------------------------------------------------------------------------------

data MockState = MockState {
    _boundSockets :: !(Map SockAddr Socket)
  , _nextSocketId :: !Int
  }

initialMockState :: MockState
initialMockState = MockState {
    _boundSockets = Map.empty
  , _nextSocketId = 0
  }

mockState :: MVar MockState
{-# NOINLINE mockState #-}
mockState = unsafePerformIO $ newMVar initialMockState

get :: Accessor MockState a -> IO a
get acc = withMVar mockState $ return . (^. acc)

set :: Accessor MockState a -> a -> IO ()
set acc val = modifyMVar_ mockState $ return . (acc ^= val) 

boundSockets :: Accessor MockState (Map SockAddr Socket)
boundSockets = accessor _boundSockets (\bs st -> st { _boundSockets = bs })

boundSocketAt :: SockAddr -> Accessor MockState (Maybe Socket)
boundSocketAt addr = boundSockets >>> DAC.mapMaybe addr

nextSocketId :: Accessor MockState Int
nextSocketId = accessor _nextSocketId (\sid st -> st { _nextSocketId = sid })

--------------------------------------------------------------------------------
-- The public API (mirroring Network.Socket)                                  --
--------------------------------------------------------------------------------

type HostName    = String
type ServiceName = String
type PortNumber  = String 
type HostAddress = String 

data SocketType   = Stream 
data SocketOption = ReuseAddr
data ShutdownCmd  = ShutdownSend

data Family
data ProtocolNumber

data Socket = Socket { 
    socketState       :: MVar SocketState
  , socketDescription :: String
  }

data SocketState = 
    Uninit
  | BoundSocket { socketBacklog :: Chan (Socket, SockAddr, MVar Socket) }
  | Connected { socketPeer :: Socket, socketBuff :: Chan Message }
  | Closed

data Message = 
    Payload Word8
  | CloseSocket

data AddrInfo = AddrInfo {
    addrFamily  :: Family
  , addrAddress :: SockAddr
  }

data SockAddr = SockAddrInet PortNumber HostAddress
  deriving (Eq, Ord, Show)

instance Show AddrInfo where
  show = show . addrAddress

instance Show Socket where
  show sock = "<<socket " ++ socketDescription sock ++ ">>"

getAddrInfo :: Maybe AddrInfo -> Maybe HostName -> Maybe ServiceName -> IO [AddrInfo]
getAddrInfo _ (Just host) (Just port) = return . return $ AddrInfo { 
    addrFamily  = error "Family unused" 
  , addrAddress = SockAddrInet port host 
  }
getAddrInfo _ _ _ = error "getAddrInfo: unsupported arguments"

defaultHints :: AddrInfo
defaultHints = error "defaultHints not implemented" 

socket :: Family -> SocketType -> ProtocolNumber -> IO Socket
socket _ Stream _ = do
  state <- newMVar Uninit
  sid   <- get nextSocketId
  set nextSocketId (sid + 1)
  return Socket { 
      socketState       = state
    , socketDescription = show sid
    }
  
bindSocket :: Socket -> SockAddr -> IO ()
bindSocket sock addr = do
  modifyMVar_ (socketState sock) $ \st -> case st of
    Uninit -> do
      backlog <- newChan
      return BoundSocket { 
          socketBacklog = backlog 
        }
    _ ->
      error "bind: socket already initialized"
  set (boundSocketAt addr) (Just sock)
  
listen :: Socket -> Int -> IO ()
listen _ _ = return () 

defaultProtocol :: ProtocolNumber
defaultProtocol = error "defaultProtocol not implemented" 

setSocketOption :: Socket -> SocketOption -> Int -> IO ()
setSocketOption _ ReuseAddr 1 = return ()
setSocketOption _ _ _ = error "setSocketOption: unsupported arguments"

accept :: Socket -> IO (Socket, SockAddr)
accept serverSock = do
  backlog <- withMVar (socketState serverSock) $ \st -> case st of
    BoundSocket {} -> 
      return (socketBacklog st)
    _ ->
      error "accept: socket not bound"
  (theirSocket, theirAddress, reply) <- readChan backlog 
  ourBuff  <- newChan
  ourState <- newMVar Connected { 
      socketPeer = theirSocket
    , socketBuff = ourBuff
    }
  let ourSocket = Socket {
      socketState       = ourState
    , socketDescription = ""
    }
  putMVar reply ourSocket 
  return (ourSocket, theirAddress)

sClose :: Socket -> IO ()
sClose sock = do
  writeSocket sock CloseSocket 
  modifyMVar_ (socketState sock) $ const (return Closed)

connect :: Socket -> SockAddr -> IO ()
connect us serverAddr = do
  mServer <- get (boundSocketAt serverAddr)
  case mServer of
    Just server -> do
      serverBacklog <- withMVar (socketState server) $ \st -> case st of
        BoundSocket {} ->
          return (socketBacklog st)
        _ ->
          error "connect: server socket not bound"
      reply <- newEmptyMVar
      writeChan serverBacklog (us, SockAddrInet "" "", reply)
      them <- readMVar reply 
      modifyMVar_ (socketState us) $ \st -> case st of
        Uninit -> do 
          buff <- newChan
          return Connected { 
              socketPeer = them 
            , socketBuff = buff
            }
        _ ->
          error "connect: already connected"
    Nothing -> error "connect: unknown address"

sOMAXCONN :: Int
sOMAXCONN = error "sOMAXCONN not implemented" 

shutdown :: Socket -> ShutdownCmd -> IO ()
shutdown = error "shutdown not implemented" 

--------------------------------------------------------------------------------
-- Functions with no direct public counterpart                                --
--------------------------------------------------------------------------------

peerBuffer :: Socket -> IO (Either String (Chan Message))
peerBuffer sock = do
  mPeer <- withMVar (socketState sock) $ \st -> case st of
    Connected {} -> 
      return (Just (socketPeer st))
    _ ->
      return Nothing
  case mPeer of
    Just peer -> withMVar (socketState peer) $ \st -> case st of
      Connected {} ->
        return (Right (socketBuff st))
      _ ->
        return (Left "Peer socket closed") 
    Nothing -> 
      return (Left "Socket closed") 

writeSocket :: Socket -> Message -> IO ()
writeSocket sock msg = do
  theirBuff <- peerBuffer sock
  case theirBuff of
    Right buff -> writeChan buff msg 
    Left err   -> case msg of Payload _   -> error $ "writeSocket: " ++ err 
                              CloseSocket -> return ()

readSocket :: Socket -> IO (Maybe Word8)
readSocket sock = do
  mBuff <- withMVar (socketState sock) $ \st -> case st of
    Connected {} -> 
      return (Just $ socketBuff st)
    _ ->
      return Nothing
  case mBuff of
    Just buff -> do
      msg <- readChan buff 
      case msg of
        Payload w -> return (Just w)
        CloseSocket -> modifyMVar (socketState sock) $ \st -> case st of
          Connected {} ->
            return (Closed, Nothing)
          _ ->
            error "readSocket: socket in unexpected state"
    Nothing -> 
      return Nothing
