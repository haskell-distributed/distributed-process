-- | Utility functions
--
-- Note: this module is bound to change even more than the rest of the API :)
module Network.Transport.Util (spawn) where

import Network.Transport
  ( Transport
  , EndPoint(..)
  , EndPointAddress
  , newEndPoint
  )
import Control.Exception (throwIO)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)

-- | Fork a new thread, create a new end point on that thread, and run the specified IO operation on that thread.
--
-- Returns the address of the new end point.
spawn :: Transport -> (EndPoint -> IO ()) -> IO EndPointAddress
spawn transport proc = do
  addrMVar <- newEmptyMVar
  forkIO $ do
    mEndPoint <- newEndPoint transport
    case mEndPoint of
      Left err ->
        putMVar addrMVar (Left err)
      Right endPoint -> do
        putMVar addrMVar (Right (address endPoint))
        proc endPoint
  mAddr <- takeMVar addrMVar
  case mAddr of
    Left err   -> throwIO err
    Right addr -> return addr
