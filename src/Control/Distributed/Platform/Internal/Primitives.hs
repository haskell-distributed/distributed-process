-- | Common Entities used throughout -platform. 
-- NB: Please DO NOT use this module as a dumping ground.
--
module Control.Distributed.Platform.Internal.Primitives
  ( spawnLinkLocal
  , spawnMonitorLocal
  )
where

import Control.Distributed.Process
  ( link
  , spawnLocal
  , monitor
  , Process()
  , ProcessId
  , MonitorRef)

-- | Node local version of 'Control.Distributed.Process.spawnLink'.
-- Note that this is just the sequential composition of 'spawn' and 'link'.
-- (The "Unified" semantics that underlies Cloud Haskell does not even support
-- a synchronous link operation)
spawnLinkLocal :: Process () -> Process ProcessId
spawnLinkLocal p = do
  pid <- spawnLocal p
  link pid
  return pid

-- | Like 'spawnLinkLocal', but monitor the spawned process
spawnMonitorLocal :: Process () -> Process (ProcessId, MonitorRef)
spawnMonitorLocal p = do
  pid <- spawnLocal p
  ref <- monitor pid
  return (pid, ref)
