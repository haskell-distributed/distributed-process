-- | Utility functions 
-- 
-- Note: this module is bound to change even more than the rest of the API :)
module Network.Transport.Util (spawn) where

import Network.Transport ( Transport
                         , EndPoint(..)
                         , EndPointAddress
                         , newEndPoint
                         )
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)

-- | Fork a new thread, create a new end point on that thread, and run the specified IO operation on that thread.
-- 
-- Returns the address of the new end point.
spawn :: Transport -> (EndPoint -> IO ()) -> IO EndPointAddress 
spawn transport proc = do
  addr <- newEmptyMVar
  forkIO $ do
    Right endpoint <- newEndPoint transport
    putMVar addr (address endpoint)
    proc endpoint
  takeMVar addr
