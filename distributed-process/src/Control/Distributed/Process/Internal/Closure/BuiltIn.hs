{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( remoteTable
  , linkClosure
  , sendClosure
  , returnClosure
  ) where

import Data.Binary (encode)
import Control.Distributed.Process (link)
import Control.Distributed.Process.Internal.Types 
  ( ProcessId
  , Closure
  , Process
  , RemoteTable
  , SerializableDict(..)
  , Closure(..)
  , Static(..)
  , StaticLabel(..)
  )
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkClosure)

remotable ['link]

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

-- | Closure version of 'link'
linkClosure :: ProcessId -> Closure (Process ())
linkClosure = $(mkClosure 'link)

-- | Closure version of 'send'
sendClosure :: SerializableDict a -> ProcessId -> Closure (a -> Process ())
sendClosure (SerializableDict label) pid =
  Closure (Static ClosureSend) (encode (label, pid)) 

-- | Return any value
returnClosure :: SerializableDict a -> a -> Closure (Process a)
returnClosure (SerializableDict label) val =
  Closure (Static ClosureReturn) (encode (label, encode val))
