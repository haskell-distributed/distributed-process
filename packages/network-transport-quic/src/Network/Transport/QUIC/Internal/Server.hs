{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Transport.QUIC.Internal.Server (forkServer) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeAsyncException, SomeException, catch, finally, fromException, mask, mask_, throwIO)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Network.QUIC qualified as QUIC
import Network.QUIC.Server qualified as QUIC.Server
import Network.Socket (Socket)
import Network.Transport.QUIC.Internal.Configuration (Credential, mkServerConfig)

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
  IO ThreadId
forkServer socket creds errorHandler terminationHandler requestHandler = do
  serverConfig <- mkServerConfig creds

  let acceptConnection :: QUIC.Connection -> IO ()
      acceptConnection conn = mask $ \restore -> do
        QUIC.waitEstablished conn
        restore (acceptStreams conn errorHandler requestHandler)

  -- We have to make sure that the exception handler is
  -- installed /before/ any asynchronous exception occurs. So we mask_, then
  -- forkIOWithUnmask (the child thread inherits the masked state from the parent), then
  -- unmask only inside the catch.
  --
  -- See the documentation for `forkIOWithUnmask`.
  mask_ $
    forkIOWithUnmask
      ( \unmask ->
          catch
            (unmask $ QUIC.Server.runWithSockets [socket] serverConfig (\conn -> catch (acceptConnection conn) errorHandler))
            terminationHandler
      )

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
