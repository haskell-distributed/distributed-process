module Control.Distributed.Process.Internal.Node 
  ( runLocalProcess
  ) where

import Control.Monad.Reader (runReaderT)
import Control.Distributed.Process.Internal.Types 
  ( LocalNode
  , LocalProcess
  , Process(unProcess)
  )
import Control.Distributed.Process.Internal.MessageT (runMessageT)  

-- | Deconstructor for 'Process' (not exported to the public API) 
runLocalProcess :: LocalNode -> Process a -> LocalProcess -> IO a
runLocalProcess node proc = runMessageT node . runReaderT (unProcess proc) 

