-- | Combine two transports into a single new transport
--
-- Given two transports A and B, endpoints in the combined transport are
-- pairs of endpoints for the underlying transports. Consequently, the address
-- of an endpoint in the combined transport is a pair of addresses of the
-- two underlying endpoints. Events from both underlying endpoints are posted
-- to the combined endpoint.
--
-- When the address of combined endpoint C1 is sent to combined endpoint C2,
-- and C2 attempts to make a connection to C1, it needs to choice an underlying
-- endpoint to make the connection. The choice is made by a parameter 
-- 'resolveAddress' of the composed transport.
--
-- When C2 connects to C1 then it is assumed that whatever transport C2 uses
-- to connect to C1, this is the same transport that C1 needs to use to connect
-- back to C2. 
module Network.Transport.Composed 
  ( ComposedTransport(..)
  , createTransport
  ) where

import qualified Data.ByteString as BSS 
  ( concat
  , length
  , splitAt
  , singleton
  , uncons
  )
import Control.Monad (void)  
import Control.Concurrent.Chan (Chan, newChan, writeChan, readChan)
import Control.Concurrent (forkIO)
import Network.Transport 
  ( Transport(..)
  , EndPointAddress(EndPointAddress)
  , TransportError(TransportError)
  , NewEndPointErrorCode
  , EndPoint(..)
  , NewMulticastGroupErrorCode(NewMulticastGroupUnsupported) 
  , ResolveMulticastGroupErrorCode(ResolveMulticastGroupUnsupported)
  , Event(EndPointClosed, ConnectionOpened, ErrorEvent)
  , EventErrorCode(EventConnectionLost)
  , Reliability
  , ConnectHints
  , ConnectErrorCode
  , Connection
  )
import Network.Transport.Internal (encodeInt32, decodeInt32)

data ComposedTransport = ComposedTransport {
    -- | The left transport
    transportA :: Transport
    -- | The right transport
  , transportB :: Transport
    -- | Pick a suitable transport for an address
  , resolveAddress :: (EndPoint, EndPoint)
                   -> (EndPointAddress, EndPointAddress) 
                   -> IO (EndPoint, EndPointAddress) 
  }

data ComposedAddress = 
    LeftAddress EndPointAddress
  | RightAddress EndPointAddress
  | EitherAddress EndPointAddress EndPointAddress

serializeComposedAddress :: ComposedAddress -> EndPointAddress
serializeComposedAddress (LeftAddress (EndPointAddress addr)) = 
  EndPointAddress $ BSS.concat [BSS.singleton 0, addr]
serializeComposedAddress (RightAddress (EndPointAddress addr)) = 
  EndPointAddress $ BSS.concat [BSS.singleton 1, addr]
serializeComposedAddress (EitherAddress (EndPointAddress addr1) (EndPointAddress addr2)) =
  EndPointAddress $ BSS.concat [BSS.singleton 2, encodeInt32 (BSS.length addr1), addr1, addr2]

deserializeComposedAddress :: EndPointAddress -> ComposedAddress
deserializeComposedAddress (EndPointAddress addr) = 
  let (header, remainder) = case BSS.uncons addr of
                              Just (x, xs) -> (x, xs)
                              Nothing      -> error "deserializeComposedAddress"
  in case header of
    0 -> LeftAddress (EndPointAddress remainder)
    1 -> RightAddress (EndPointAddress remainder)
    2 -> let (len, remainder') = BSS.splitAt 4 remainder
             (a, b) = BSS.splitAt (decodeInt32 len) remainder'
         in EitherAddress (EndPointAddress a) (EndPointAddress b)
    _ -> error "deserializeComposedAddress"
  
createTransport :: ComposedTransport -> IO Transport 
createTransport composed = 
  return Transport {
      newEndPoint    = apiNewEndPoint composed 
    , closeTransport = apiCloseTransport composed 
    }
                
apiNewEndPoint :: ComposedTransport -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint composed = do 
    mEndPoints <- createEndPoints 
    case mEndPoints of
      Left err -> 
        return $ Left err
      Right (endPointA, endPointB) -> do
        let addr = serializeComposedAddress (EitherAddress (address endPointA) (address endPointB))
        chan <- newChan
        void . forkIO $ forwardEvents endPointA chan LeftAddress
        void . forkIO $ forwardEvents endPointB chan RightAddress
        return . Right $ EndPoint {
            receive       = readChan chan 
          , address       = addr 
          , connect       = apiConnect composed endPointA endPointB 
          , closeEndPoint = apiCloseEndPoint endPointA endPointB
          , newMulticastGroup     = return . Left $ newMulticastGroupError 
          , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
          }
  where
    newMulticastGroupError = 
      TransportError NewMulticastGroupUnsupported "Multicast not supported" 
    resolveMulticastGroupError = 
      TransportError ResolveMulticastGroupUnsupported "Multicast not supported" 

    createEndPoints = do
      mEndPointA <- newEndPoint (transportA composed) 
      case mEndPointA of
        Left err -> return $ Left err
        Right endPointA -> do
          mEndPointB <- newEndPoint (transportB composed)
          case mEndPointB of
            Left err -> do
              closeEndPoint endPointA
              return $ Left err
            Right endPointB -> 
              return $ Right (endPointA, endPointB)

    forwardEvents :: EndPoint -> Chan Event -> (EndPointAddress -> ComposedAddress) -> IO ()
    forwardEvents endPoint chan inj = go
      where
        go = do
          event <- receive endPoint
          case event of
            ConnectionOpened cid rel addr -> do 
              let addr' = serializeComposedAddress (inj addr)
              writeChan chan (ConnectionOpened cid rel addr')
              go 
            ErrorEvent (TransportError (EventConnectionLost addr) msg) -> do
              let addr' = serializeComposedAddress (inj addr)
              writeChan chan $ ErrorEvent (TransportError (EventConnectionLost addr') msg)
              go
            EndPointClosed ->  do
              writeChan chan event 
              return ()
            _ -> do
              writeChan chan event 
              go

apiCloseTransport :: ComposedTransport -> IO ()
apiCloseTransport composed = do
  closeTransport (transportA composed)
  closeTransport (transportB composed)

apiConnect :: ComposedTransport
           -> EndPoint
           -> EndPoint
           -> EndPointAddress 
           -> Reliability 
           -> ConnectHints 
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect composed endPointA endPointB theirComposedAddr rel hints = 
  case deserializeComposedAddress theirComposedAddr of
    LeftAddress addr -> 
      connect endPointA addr rel hints
    RightAddress addr -> 
      connect endPointB addr rel hints
    EitherAddress addrA addrB -> do
      (endPoint, addr) <- resolveAddress composed (endPointA, endPointB) (addrA, addrB)
      connect endPoint addr rel hints

apiCloseEndPoint :: EndPoint -> EndPoint -> IO ()
apiCloseEndPoint endPointA endPointB = do                 
  closeEndPoint endPointA
  closeEndPoint endPointB
