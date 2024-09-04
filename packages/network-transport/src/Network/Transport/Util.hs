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

-- | Create a new end point, fork a new thread, and run the specified IO operation on that thread.
--
-- Returns the address of the new end point.
spawn :: Transport -> (EndPoint -> IO ()) -> IO EndPointAddress
spawn transport proc = do
  -- `newEndPoint` used to be done in a separate thread, in case it was slow.
  -- However, in this case, care must be taken to appropriately handle asynchronous exceptions.
  -- Instead, for reliability, we now create the new endpoint in this thread.
  mEndPoint <- newEndPoint transport
  case mEndPoint of
    Left err -> throwIO err
    Right endPoint -> do
      forkIO $ proc endPoint
      return $ address endPoint
