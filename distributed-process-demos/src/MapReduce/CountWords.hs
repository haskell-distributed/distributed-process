{-# LANGUAGE TupleSections #-}
module CountWords 
  ( Document
  , localCountWords
  , distrCountWords
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import MapReduce hiding (__remoteTable) 

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

dictIn :: SerializableDict (FilePath, Document)
dictIn = SerializableDict

dictOut :: SerializableDict [(Word, Frequency)]
dictOut = SerializableDict

countWords_ :: () -> MapReduce FilePath Document Word Frequency Frequency
countWords_ () = countWords

remotable ['dictIn, 'dictOut, 'countWords_]

distrCountWords :: [NodeId] -> Map FilePath Document -> Process (Map Word Frequency)
distrCountWords mappers input = 
  distrMapReduce $(mkStatic 'dictIn)
                 $(mkStatic 'dictOut) 
                 ($(mkClosure 'countWords_) ())
                 mappers
                 (\iteration -> iteration input)
