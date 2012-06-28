{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( remoteTable
  , linkClosure
  , sendClosure
  , returnClosure
  ) where

import Data.Binary (encode)
import Data.Typeable (typeOf)
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
sendClosure :: forall a. SerializableDict a -> ProcessId -> Closure (a -> Process ())
sendClosure SerializableDict pid =
  Closure (Static ClosureSend) (encode (typeOf (undefined :: a), pid)) 

-- | Return any value
returnClosure :: forall a. SerializableDict a -> a -> Closure (Process a)
returnClosure SerializableDict val =
  Closure (Static ClosureReturn) (encode (typeOf (undefined :: a), encode val))
