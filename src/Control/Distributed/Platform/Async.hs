{-# LANGUAGE DeriveDataTypeable #-}
module Control.Distributed.Platform.Async (
    Async(),
    async,
    wait,
    waitTimeout
  ) where
import           Control.Concurrent.MVar
import           Control.Distributed.Platform.Internal.Types
import           Control.Distributed.Platform.Timer
import           Control.Distributed.Process                 (Process,
                                                              ProcessId, ProcessMonitorNotification (..),
                                                              finally, liftIO,
                                                              match, monitor,
                                                              receiveTimeout,
                                                              receiveWait,
                                                              unmonitor)
import           Control.Distributed.Process.Internal.Types  (MonitorRef)
import           Control.Distributed.Process.Serializable    (Serializable)
import           Data.Maybe                                  (fromMaybe)


-- | Async data type
data Async a = Async MonitorRef (MVar a)

-- |
async :: (Serializable b) => ProcessId -> Process () -> Process (Async b)
async sid proc = do
  ref <- monitor sid
  proc
  mvar <- liftIO newEmptyMVar
  return $ Async ref mvar

-- | Wait for the call response
wait :: (Serializable a, Show a) => Async a -> Process a
wait a = waitTimeout a Infinity >>= return . fromMaybe (error "Receive wait timeout")

-- | Wait for the call response given a timeout
waitTimeout :: (Serializable a, Show a) => Async a -> Timeout -> Process (Maybe a)
waitTimeout (Async ref respMVar) timeout = do
    respM <- liftIO $ tryTakeMVar respMVar
    case respM of
      Nothing -> do
        respM' <- finally (receive timeout) (unmonitor ref)
        case respM' of
          Just resp -> do
            liftIO $ putMVar respMVar resp
            return respM'
          _ -> return respM'
      _ -> return respM
  where
    receive to = case to of
        Infinity -> receiveWait matches >>= return . Just
        Timeout t -> receiveTimeout (intervalToMs t) matches
    matches = [
      match return,
      match (\(ProcessMonitorNotification _ _ reason) ->
        receiveTimeout 0 [match return] >>= return . fromMaybe (error $ "Server died: " ++ show reason))]
