{-# LANGUAGE ExistentialQuantification #-}
module Control.Concurrent.Utils
  ( Lock()
  , mkExclusiveLock
  , mkQLock
  , withLock
  ) where

import Control.Monad.Catch (MonadMask)
import qualified Control.Monad.Catch as Catch
import Control.Concurrent.MVar
  ( newMVar
  , takeMVar
  , putMVar
  )
import Control.Concurrent.QSem
import Control.Monad.IO.Class (MonadIO, liftIO)

-- | Opaque lock.
data Lock = forall l . Lock l (l -> IO ()) (l -> IO ())

-- | Take a lock.
acquire :: MonadIO m => Lock -> m ()
acquire (Lock l acq _) = liftIO $ acq l

-- | Release lock.
release :: MonadIO m => Lock -> m ()
release (Lock l _ rel) = liftIO $ rel l

-- | Create exclusive lock. Only one process could take such lock.
mkExclusiveLock :: IO Lock
mkExclusiveLock = Lock <$> newMVar () <*> pure takeMVar <*> pure (flip putMVar ())

-- | Create quantity lock. A fixed number of processes can take this lock simultaniously.
mkQLock :: Int -> IO Lock
mkQLock n = Lock <$> newQSem n <*> pure waitQSem <*> pure signalQSem

-- | Run action under a held lock.
withLock :: (MonadMask m, MonadIO m) => Lock -> m a -> m a
withLock excl =
  Catch.bracket_  (acquire excl)
                  (release excl)
