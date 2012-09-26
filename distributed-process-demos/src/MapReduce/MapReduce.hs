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
import qualified Control.Concurrent.Chan as Chan
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply, staticCompose, staticApply)
import Control.Concurrent (threadDelay)

--------------------------------------------------------------------------------
-- Definition of a MapReduce skeleton and a local implementation              --
--------------------------------------------------------------------------------

-- | MapReduce skeleton
data MapReduce k1 v1 k2 v2 v3 = MapReduce {
    mrMap    :: k1 -> v1 -> [(k2, v2)]
  , mrReduce :: k2 -> [v2] -> v3
  } deriving (Typeable)

-- | Local (non-distributed) implementation of the map-reduce algorithm
--
-- This can be regarded as the specification of map-reduce; see
-- /Google’s MapReduce Programming Model---Revisited/ by Ralf Laemmel
-- (<http://userpages.uni-koblenz.de/~laemmel/MapReduce/>).
localMapReduce :: forall k1 k2 v1 v2 v3. Ord k2 =>
                  MapReduce k1 v1 k2 v2 v3 
               -> Map k1 v1 
               -> Map k2 v3
localMapReduce mr = reducePerKey mr . groupByKey . mapPerKey mr

reducePerKey :: MapReduce k1 v1 k2 v2 v3 -> Map k2 [v2] -> Map k2 v3
reducePerKey mr = Map.mapWithKey (mrReduce mr) 

groupByKey :: Ord k2 => [(k2, v2)] -> Map k2 [v2]
groupByKey = Map.fromListWith (++) . map (second return) 

mapPerKey :: MapReduce k1 v1 k2 v2 v3 -> Map k1 v1 -> [(k2, v2)]
mapPerKey mr = concatMap (uncurry (mrMap mr)) . Map.toList 

--------------------------------------------------------------------------------
-- Simple distributed implementation                                          --
--------------------------------------------------------------------------------

matchDict :: forall a b. SerializableDict a -> (a -> Process b) -> Match b
matchDict SerializableDict = match

sendDict :: forall a. SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

mapperProcess :: forall k1 v1 k2 v2 v3. 
                 SerializableDict (ProcessId, k1, v1)
              -> SerializableDict [(k2, v2)]
              -> ProcessId
              -> MapReduce k1 v1 k2 v2 v3 
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

mapperProcessClosure :: forall k1 v1 k2 v2 v3. 
                        (Typeable k1, Typeable v1, Typeable k2, Typeable v2, Typeable v3)
                     => Static (SerializableDict (ProcessId, k1, v1))
                     -> Static (SerializableDict [(k2, v2)])
                     -> Closure (MapReduce k1 v1 k2 v2 v3) 
                     -> ProcessId 
                     -> Closure (Process ())
mapperProcessClosure dictIn dictOut mr pid = 
    closure decoder (encode pid) `closureApply` mr
  where
    decoder :: Static (ByteString -> MapReduce k1 v1 k2 v2 v3 -> Process ())
    decoder = 
        ($(mkStatic 'mapperProcess) `staticApply` dictIn `staticApply` dictOut)
      `staticCompose` 
        staticDecode sdictProcessId

distrMapReduce :: forall k1 k2 v1 v2 v3 a. 
                  (Serializable k1, Serializable v1, Serializable k2, Serializable v2, Serializable v3, Ord k2)
               => Static (SerializableDict (ProcessId, k1, v1))
               -> Static (SerializableDict [(k2, v2)])
               -> Closure (MapReduce k1 v1 k2 v2 v3)
               -> [NodeId]
               -> ((Map k1 v1 -> Process (Map k2 v3)) -> Process a) 
               -> Process a 
distrMapReduce dictIn dictOut mr mappers p = do
  mr' <- unClosure mr
  us <- getSelfPid
  queue <- liftIO $ Chan.newChan
  slavesTerminated <- liftIO $ newEmptyMVar
 
  workQueue <- spawnLocal $ do
    let go :: Process ()
        go = do 
          mWork <- liftIO $ Chan.readChan queue
          case mWork of
            Just (key, val) -> do
              -- As long there is work, make it available to the mappers 
              them <- expect
              send them (us, key, val)
              go
            Nothing -> do
              -- Tell the mappers to terminate
              replicateM (length mappers) $ do
                them <- expect
                send them ()
              liftIO $ putMVar slavesTerminated ()
    go

  -- Start the mappers
  forM_ mappers $ flip spawn (mapperProcessClosure dictIn dictOut mr workQueue) 

  let iteration :: Map k1 v1 -> Process (Map k2 v3)
      iteration input = do
        -- Make work available to the mappers
        liftIO $ mapM_ (Chan.writeChan queue . Just) (Map.toList input)

        -- Wait for the partial results
        partials <- replicateM (Map.size input) expect 

        -- We reduce on this node
        return (reducePerKey mr' . groupByKey . concat $ partials)

  result <- p iteration

  -- Terminate the wrappers
  liftIO $ do
    Chan.writeChan queue Nothing
    takeMVar slavesTerminated

  return result
