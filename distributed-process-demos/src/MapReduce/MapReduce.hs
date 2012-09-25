{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable, GADTs #-}
module MapReduce 
  ( -- * Map-reduce skeleton and implementation
    MapReduce(..)
  , localMapReduce
  , distrMapReduce 
  , __remoteTable
    -- * Re-exports from Data.Map
  , Map
  ) where

import Data.Typeable (Typeable)
import Data.Binary (encode)
import Data.ByteString.Lazy (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map (mapWithKey, fromListWith, toList, size)
import Control.Arrow (second)
import Control.Monad (forM_, forever, replicateM)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply, staticCompose, staticApply)
import Control.Concurrent (threadDelay)

--------------------------------------------------------------------------------
-- Definition of a MapReduce skeleton and a local implementation              --
--------------------------------------------------------------------------------

-- | MapReduce skeleton
data MapReduce k1 v1 k2 v2 = MapReduce {
    mrMap    :: k1 -> v1 -> [(k2, v2)]
  , mrReduce :: k2 -> [v2] -> v2
  } deriving (Typeable)

-- | Local (non-distributed) implementation of the map-reduce algorithm
--
-- This can be regarded as the specification of map-reduce; see
-- /Google’s MapReduce Programming Model---Revisited/ by Ralf Laemmel
-- (<http://userpages.uni-koblenz.de/~laemmel/MapReduce/>).
localMapReduce :: forall k1 k2 v1 v2. Ord k2 =>
                  MapReduce k1 v1 k2 v2 
               -> Map k1 v1 
               -> Map k2 v2
localMapReduce mr = reducePerKey mr . groupByKey . mapPerKey mr

reducePerKey :: MapReduce k1 v1 k2 v2 -> Map k2 [v2] -> Map k2 v2
reducePerKey mr = Map.mapWithKey (mrReduce mr) 

groupByKey :: Ord k2 => [(k2, v2)] -> Map k2 [v2]
groupByKey = Map.fromListWith (++) . map (second return) 

mapPerKey :: MapReduce k1 v1 k2 v2 -> Map k1 v1 -> [(k2, v2)]
mapPerKey mr = concatMap (uncurry (mrMap mr)) . Map.toList 

--------------------------------------------------------------------------------
-- Simple distributed implementation                                          --
--------------------------------------------------------------------------------

matchDict :: forall a b. SerializableDict a -> (a -> Process b) -> Match b
matchDict SerializableDict = match

sendDict :: forall a. SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

mapperProcess :: forall k1 v1 k2 v2. 
                 SerializableDict (ProcessId, k1, v1)
              -> SerializableDict [(k2, v2)]
              -> ProcessId
              -> MapReduce k1 v1 k2 v2 
              -> Process ()
mapperProcess dictIn dictOut workQueue mr = do
    us <- getSelfPid
    liftIO . putStrLn $ "Mapper " ++ show us ++ " started"
    go us
  where
    go us = do
      -- Ask the queue for work 
      send workQueue us
  
      liftIO . putStrLn $ "Mapper " ++ show us ++ " waiting for work"
      -- Wait for a reply
      mWork <- receiveWait 
        [ matchDict dictIn $ \(pid, key, val) -> return $ Just (pid, key, val)
        , match $ \() -> return Nothing
        ]

      -- If there is work, do it and repeat; otherwise, exit
      case mWork of
        Just (pid, key, val) -> do
          sendDict dictOut pid (mrMap mr key val)
          go us

        Nothing -> do 
          liftIO $ putStrLn "Slave exiting"
          return ()
      
remotable ['mapperProcess]

mapperProcessClosure :: forall k1 v1 k2 v2. 
                        (Typeable k1, Typeable v1, Typeable k2, Typeable v2)
                     => Static (SerializableDict (ProcessId, k1, v1))
                     -> Static (SerializableDict [(k2, v2)])
                     -> Closure (MapReduce k1 v1 k2 v2) 
                     -> ProcessId 
                     -> Closure (Process ())
mapperProcessClosure dictIn dictOut mr pid = 
    closure decoder (encode pid) `closureApply` mr
  where
    decoder :: Static (ByteString -> MapReduce k1 v1 k2 v2 -> Process ())
    decoder = 
        ($(mkStatic 'mapperProcess) `staticApply` dictIn `staticApply` dictOut)
      `staticCompose` 
        staticDecode sdictProcessId

distrMapReduce :: forall k1 k2 v1 v2. 
                  (Serializable k1, Serializable v1, Serializable k2, Serializable v2, Ord k2)
               => Static (SerializableDict (ProcessId, k1, v1))
               -> Static (SerializableDict [(k2, v2)])
               -> Closure (MapReduce k1 v1 k2 v2)
               -> [NodeId]
               -> Map k1 v1 
               -> Process (Map k2 v2)
distrMapReduce dictIn dictOut mr mappers input = do
  us <- getSelfPid
  slavesTerminated <- liftIO $ newEmptyMVar

  workQueue <- spawnLocal $ do
    -- As long as there is work, return the next Fib to compute
    forM_ (Map.toList input) $ \(key, val) -> do
      them <- expect 
      send them (us, key, val)

    -- After that, just report that the work is done
    replicateM (length mappers) $ do
      pid <- expect
      send pid ()

    liftIO $ putMVar slavesTerminated ()

  -- Start the mappers
  liftIO $ print mappers
  forM_ mappers $ flip spawn (mapperProcessClosure dictIn dictOut mr workQueue) 

  liftIO $ threadDelay 1000000

  -- Wait for the result from the mappers
  partials <- replicateM (Map.size input) expect 
  
  -- Wait for the slaves to terminate
  liftIO $ takeMVar slavesTerminated

  -- We reduce on this node
  mr' <- unClosure mr
  return (reducePerKey mr' . groupByKey . concat $ partials)
