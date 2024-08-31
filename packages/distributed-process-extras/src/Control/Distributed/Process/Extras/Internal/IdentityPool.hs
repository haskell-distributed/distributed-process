module Control.Distributed.Process.Extras.Internal.IdentityPool where

-- import Control.Concurrent.STM (atomically)
-- import Control.Concurrent.STM.TChan (newTChanIO, readTChan, writeTChan)
import Control.Distributed.Process.Extras.Internal.Queue.PriorityQ (PriorityQ)
import qualified Control.Distributed.Process.Extras.Internal.Queue.PriorityQ as Queue

data IdentityPool a = IDPool { reserved :: !a
                             , returns  :: PriorityQ a a
                             }

