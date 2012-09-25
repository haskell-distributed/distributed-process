{-# LANGUAGE TupleSections #-}
module CountWords 
  ( Document
  , localCountWords
  , distrCountWords
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Static (staticClosure)
import MapReduce hiding (__remoteTable) 

type Document  = String
type Word      = String
type Frequency = Int

countWords :: MapReduce FilePath Document Word Frequency 
countWords = MapReduce {
    mrMap    = const (map (, 1) . words)
  , mrReduce = const sum  
  }

localCountWords :: Map FilePath Document -> Map Word Frequency
localCountWords = localMapReduce countWords

dictIn :: SerializableDict (ProcessId, FilePath, Document)
dictIn = SerializableDict

dictOut :: SerializableDict [(Word, Frequency)]
dictOut = SerializableDict

remotable ['dictIn, 'dictOut, 'countWords]

distrCountWords :: [NodeId] -> Map FilePath Document -> Process (Map Word Frequency)
distrCountWords = distrMapReduce $(mkStatic 'dictIn)
                                 $(mkStatic 'dictOut) 
                                 (staticClosure $(mkStatic 'countWords)) 
