{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Control.Concurrent.Utils
  ( Lock()
  , Exclusive(..)
  , Synchronised(..)
  , withLock
  ) where

import Control.Distributed.Process
  ( Process
  )
import qualified Control.Distributed.Process as Process (catch)
import Control.Exception (SomeException, throw)
import qualified Control.Exception as Exception (catch)
import Control.Concurrent.MVar
  ( MVar
  , tryPutMVar
  , newMVar
  , takeMVar
  )
import Control.Monad.IO.Class (MonadIO, liftIO)

newtype Lock = Lock { mvar :: MVar () }

class Exclusive a where
  new          :: IO a
  acquire      :: (MonadIO m) => a -> m ()
  release      :: (MonadIO m) => a -> m ()

instance Exclusive Lock where
  new       = return . Lock =<< newMVar ()
  acquire   = liftIO . takeMVar . mvar
  release l = liftIO (tryPutMVar (mvar l) ()) >> return ()

class Synchronised e m where
  synchronised :: (Exclusive e, Monad m) => e -> m b -> m b

  synchronized :: (Exclusive e, Monad m) => e -> m b -> m b
  synchronized = synchronised

instance Synchronised Lock IO where
  synchronised = withLock

instance Synchronised Lock Process where
  synchronised = withLockP

withLockP :: (Exclusive e) => e -> Process a -> Process a
withLockP excl act = do
  Process.catch (do { liftIO $ acquire excl
                    ; result <- act
                    ; liftIO $ release excl
                    ; return result
                    })
                (\(e :: SomeException) -> (liftIO $ release excl) >> throw e)

withLock :: (Exclusive e) => e -> IO a -> IO a
withLock excl act = do
  Exception.catch (do { acquire excl
                      ; result <- act
                      ; release excl
                      ; return result
                      })
                  (\(e :: SomeException) -> release excl >> throw e)
