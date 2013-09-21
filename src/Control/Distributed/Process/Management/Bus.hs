-- | Interface to the management event bus.
module Control.Distributed.Process.Management.Bus
  ( publishEvent
  ) where

import Control.Distributed.Process.Internal.CQueue
  ( CQueue
  , enqueue
  )
import Control.Distributed.Process.Internal.Types
  ( LocalNode(..)
  , MxEventBus(..)
  , Message
  , ProcessId
  , DiedReason
  , NodeId
  )
import Data.Foldable (forM_)
import Data.Typeable (Typeable)
import Network.Transport
  ( ConnectionId
  , EndPointAddress
  )
import System.Mem.Weak (deRefWeak)

publishEvent :: MxEventBus -> Message -> IO ()
publishEvent MxEventBusInitialising _     = return ()
publishEvent (MxEventBus _ _ wqRef _) msg =  do
  mQueue <- deRefWeak wqRef
  forM_ mQueue $ \queue -> enqueue queue msg

