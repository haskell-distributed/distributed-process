module Control.Distributed.Process.Internal.IdentityPool where

-- import Control.Concurrent.STM (atomically)
-- import Control.Concurrent.STM.TChan (newTChanIO, readTChan, writeTChan)
import Control.Distributed.Process.Platform.Internal.Queue.PriorityQ (PriorityQ)
import qualified Control.Distributed.Process.Platform.Internal.Queue.PriorityQ as Queue

data IdentityPool a = IDPool { reserved :: !a
                             , returns  :: PriorityQ a a
                             }

