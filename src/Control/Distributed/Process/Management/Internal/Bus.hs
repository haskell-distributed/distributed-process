-- | Interface to the management event bus.
module Control.Distributed.Process.Management.Internal.Bus
  ( publishEvent
  ) where

import Control.Distributed.Process.Internal.CQueue
  ( enqueue
  )
import Control.Distributed.Process.Internal.Types
  ( MxEventBus(..)
  , Message
  )
import Data.Foldable (forM_)
import System.Mem.Weak (deRefWeak)

publishEvent :: MxEventBus -> Message -> IO ()
publishEvent MxEventBusInitialising _     = return ()
publishEvent (MxEventBus _ _ wqRef _) msg =  do
  mQueue <- deRefWeak wqRef
  forM_ mQueue $ \queue -> enqueue queue msg

