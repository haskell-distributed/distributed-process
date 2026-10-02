{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal.Server (forkServer, stopServer) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeAsyncException, SomeException, catch, finally, fromException, mask, mask_, throwIO)
import Control.Monad (filterM, unless, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List.NonEmpty (NonEmpty)
import GHC.Conc (ThreadStatus (..), threadStatus)
import Network.QUIC qualified as QUIC
import Network.QUIC.Internal (isConnectionClosed, mainThreadId)
import Network.QUIC.Server (scInstallShutdownHandler)
import Network.QUIC.Server qualified as QUIC.Server
import Network.Socket (Socket)
import Network.Transport.QUIC.Internal.Configuration (Credential, mkServerConfig)
import Network.Transport.QUIC.Internal.Messaging (closeTimeout)
import System.Timeout (timeout)

data ServerHandle = ServerHandle
  { serverThread :: !ThreadId,
    serverStop :: !(MVar (IO ())),
    serverFinished :: !(MVar ()),
    serverConnections :: !(MVar [QUIC.Connection])
  }

stopServer :: ServerHandle -> IO ()
stopServer ServerHandle {..} = do
  tryReadMVar serverStop >>= \case
    Nothing -> pure ()
    Just stop -> do
      _ <- timeout closeTimeout (readMVar serverConnections >>= awaitWindingDown)
      stop >> void (timeout (2 * closeTimeout) (readMVar serverFinished))
  killThread serverThread
  where
    awaitWindingDown conns = do
      closing <- filterM windingDown conns
      unless (null closing) $ threadDelay 1_000 >> awaitWindingDown closing
      where
        windingDown conn = do
          closed <- isConnectionClosed conn
          if closed then isRunning (mainThreadId conn) else pure False

isRunning :: ThreadId -> IO Bool
isRunning tid =
  threadStatus tid >>= \case
    ThreadFinished -> pure False
    ThreadDied -> pure False
    ThreadBlocked _ -> pure True
    ThreadRunning -> pure True

forkServer ::
  Socket ->
  NonEmpty Credential ->
  -- | Error handler that runs whenever an exception is thrown inside
  --  the thread that accepted an incoming connection, or a thread
  --  that handles one of its streams
  (SomeException -> IO ()) ->
  -- | Termination handler that runs if the server thread catches an exception
  (SomeException -> IO ()) ->
  -- | Request handler. Runs once per stream; a QUIC connection may carry many.
  -- The stream is closed after this handler returns.
  (QUIC.Stream -> IO ()) ->
  IO ServerHandle
forkServer socket creds errorHandler terminationHandler requestHandler = do
  baseConfig <- mkServerConfig creds
  stopVar <- newEmptyMVar
  finished <- newEmptyMVar
  accepted <- newMVar []
  let serverConfig = baseConfig {scInstallShutdownHandler = void . tryPutMVar stopVar}

  let acceptConnection :: QUIC.Connection -> IO ()
      acceptConnection conn = mask $ \restore -> do
        QUIC.waitEstablished conn
        modifyMVar_ accepted (\conns -> (conn :) <$> filterM (isRunning . mainThreadId) conns)
        restore (acceptStreams conn errorHandler requestHandler)

  -- We have to make sure that the exception handler is
  -- installed /before/ any asynchronous exception occurs. So we mask_, then
  -- forkIOWithUnmask (the child thread inherits the masked state from the parent), then
  -- unmask only inside the catch.
  --
  -- See the documentation for `forkIOWithUnmask`.
  tid <-
    mask_ $
      forkIOWithUnmask
        ( \unmask ->
            ( catch
                (unmask $ QUIC.Server.runWithSockets [socket] serverConfig (\conn -> catch (acceptConnection conn) errorHandler))
                terminationHandler
            )
              `finally` tryPutMVar finished ()
        )
  pure ServerHandle {serverThread = tid, serverStop = stopVar, serverFinished = finished, serverConnections = accepted}

-- | Accept the streams of a connection, handling each in its own thread.
acceptStreams ::
  QUIC.Connection ->
  (SomeException -> IO ()) ->
  (QUIC.Stream -> IO ()) ->
  IO ()
acceptStreams conn errorHandler requestHandler = do
  handlers <- newIORef (mempty :: IntMap ThreadId)

  let loop :: Int -> IO ()
      loop !n = do
        stream <- QUIC.acceptStream conn
        mask_ $ do
          registered <- newEmptyMVar
          tid <- forkIOWithUnmask $ \unmask -> do
            takeMVar registered
            ( unmask (requestHandler stream `finally` QUIC.closeStream stream)
                `catch` \(exc :: SomeException) -> case fromException exc of
                  -- Being cancelled because the connection ended is expected
                  Just (_ :: SomeAsyncException) -> throwIO exc
                  Nothing -> errorHandler exc
              )
              `finally` atomicModifyIORef' handlers (\m -> (IntMap.delete n m, ()))
          atomicModifyIORef' handlers (\m -> (IntMap.insert n tid m, ()))
          putMVar registered ()
        loop (n + 1)

  loop 0 `finally` (readIORef handlers >>= mapM_ killThread . IntMap.elems)
