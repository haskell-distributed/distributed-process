{-# LANGUAGE TupleSections #-}
module CountWords 
  ( Document
  , localCountWords
  , distrCountWords
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import MapReduce 
import MonoDistrMapReduce hiding (__remoteTable) 

type Document  = String
type Word      = String
type Frequency = Int

countWords :: MapReduce FilePath Document Word Frequency Frequency
countWords = MapReduce {
    mrMap    = const (map (, 1) . words)
  , mrReduce = const sum  
  }

localCountWords :: Map FilePath Document -> Map Word Frequency
localCountWords = localMapReduce countWords

countWords_ :: () -> MapReduce FilePath Document Word Frequency Frequency
countWords_ () = countWords

remotable ['countWords_]

distrCountWords :: [NodeId] -> Map FilePath Document -> Process (Map Word Frequency)
distrCountWords = distrMapReduce ($(mkClosure 'countWords_) ())
  
