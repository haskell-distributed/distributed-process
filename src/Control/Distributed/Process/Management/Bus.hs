-- | Interface to the management event bus.
module Control.Distributed.Process.Management.Bus
  ( publishEvent
  ) where

import Control.Distributed.Process.Internal.CQueue
  ( enqueue
  )
import Control.Distributed.Process.Internal.Types
  ( MxEventBus(..)
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

data MxEvent =
    MxSpawned        ProcessId
    -- ^ fired whenever a local process is spawned
  | MxRegistered     ProcessId    String
    -- ^ fired whenever a process/name is registered (locally)
  | MxUnRegistered   ProcessId    String
    -- ^ fired whenever a process/name is unregistered (locally)
  | MxProcessDied           ProcessId    DiedReason
    -- ^ fired whenever a process dies
  | MxNodeDied       NodeId       DiedReason
    -- ^ fired whenever a node /dies/ (i.e., the connection is broken/disconnected)
  | MxSent           ProcessId    ProcessId Message
    -- ^ fired whenever a message is sent from a local process
  | MxReceived       ProcessId    Message
    -- ^ fired whenever a message is received by a local process
  | MxConnected      ConnectionId EndPointAddress
    -- ^ fired when a network-transport connection is first established
  | MxDisconnected   ConnectionId
    -- ^ fired when a network-transport connection is broken/disconnected
  | MxUser           Message
    -- ^ a user defined trace event (see 'traceMessage')
    deriving (Typeable, Show)

publishEvent :: MxEventBus -> Message -> IO ()
publishEvent MxEventBusInitialising _     = return ()
publishEvent (MxEventBus _ _ wqRef _) msg =  do
  mQueue <- deRefWeak wqRef
  forM_ mQueue $ \queue -> enqueue queue msg

