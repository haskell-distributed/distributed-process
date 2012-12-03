-- | Polymorphic "multi-shot" distributed implementation of map-reduce
module PolyDistrMapReduce (distrMapReduce, __remoteTable) where

import Data.Typeable (Typeable)
import Data.Binary (encode)
import Data.ByteString.Lazy (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map (size, toList)
import Control.Monad (forM_, replicateM, replicateM_)
import Control.Distributed.Process
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Closure
import Control.Distributed.Static (closureApply, staticCompose, staticApply)
import MapReduce (MapReduce(..), reducePerKey, groupByKey)

--------------------------------------------------------------------------------
-- Simple distributed implementation                                          --
--------------------------------------------------------------------------------

matchDict :: forall a b. SerializableDict a -> (a -> Process b) -> Match b
matchDict SerializableDict = match

sendDict :: forall a. SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

sdictProcessIdPair :: SerializableDict (ProcessId, ProcessId)
sdictProcessIdPair = SerializableDict

mapperProcess :: forall k1 v1 k2 v2 v3.
                 SerializableDict (k1, v1)
              -> SerializableDict [(k2, v2)]
              -> (ProcessId, ProcessId)
              -> MapReduce k1 v1 k2 v2 v3
              -> Process ()
mapperProcess dictIn dictOut (master, workQueue) mr = getSelfPid >>= go
  where
    go us = do
      -- Ask the queue for work
      send workQueue us

      -- Wait for a reply; if there is work, do it and repeat; otherwise, exit
      receiveWait
        [ matchDict dictIn $ \(key, val) -> do
            sendDict dictOut master (mrMap mr key val)
            go us
        , match $ \() ->
            return ()
        ]

remotable ['mapperProcess, 'sdictProcessIdPair]

mapperProcessClosure :: forall k1 v1 k2 v2 v3.
                        (Typeable k1, Typeable v1, Typeable k2, Typeable v2, Typeable v3)
                     => Static (SerializableDict (k1, v1))
                     -> Static (SerializableDict [(k2, v2)])
                     -> Closure (MapReduce k1 v1 k2 v2 v3)
                     -> ProcessId
                     -> ProcessId
                     -> Closure (Process ())
mapperProcessClosure dictIn dictOut mr master workQueue =
    closure decoder (encode (master, workQueue)) `closureApply` mr
  where
    decoder :: Static (ByteString -> MapReduce k1 v1 k2 v2 v3 -> Process ())
    decoder =
        ($(mkStatic 'mapperProcess) `staticApply` dictIn `staticApply` dictOut)
      `staticCompose`
        staticDecode $(mkStatic 'sdictProcessIdPair)

distrMapReduce :: forall k1 k2 v1 v2 v3 a.
                  (Serializable k1, Serializable v1, Serializable k2, Serializable v2, Serializable v3, Ord k2)
               => Static (SerializableDict (k1, v1))
               -> Static (SerializableDict [(k2, v2)])
               -> Closure (MapReduce k1 v1 k2 v2 v3)
               -> [NodeId]
               -> ((Map k1 v1 -> Process (Map k2 v3)) -> Process a)
               -> Process a
distrMapReduce dictIn dictOut mr mappers p = do
  mr'    <- unClosure mr
  master <- getSelfPid

  workQueue <- spawnChannelLocal $ \queue -> do
    let go :: Process ()
        go = do
          mWork <- receiveChan queue
          case mWork of
            Just (key, val) -> do
              -- As long there is work, make it available to the mappers
              them <- expect
              send them (key, val)
              go
            Nothing -> do
              -- Tell the mappers to terminate
              replicateM_ (length mappers) $ do
                them <- expect
                send them ()

              -- Tell the master that the slaves are terminated
              send master ()
    go

  -- Start the mappers
  let workQueuePid = sendPortProcessId (sendPortId workQueue)
  forM_ mappers $ \nid ->
    spawn nid (mapperProcessClosure dictIn dictOut mr master workQueuePid)

  let iteration :: Map k1 v1 -> Process (Map k2 v3)
      iteration input = do
        -- Make work available to the mappers
        mapM_ (sendChan workQueue . Just) (Map.toList input)

        -- Wait for the partial results
        partials <- replicateM (Map.size input) expect

        -- We reduce on this node
        return (reducePerKey mr' . groupByKey . concat $ partials)

  result <- p iteration

  -- Terminate the wrappers
  sendChan workQueue Nothing
  expect :: Process ()

  return result
