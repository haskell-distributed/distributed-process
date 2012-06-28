module Control.Distributed.Process.Internal.Closure.BuiltIn where 

import Control.Distributed.Process.Internal.Types 
  ( ProcessId
  , Closure
  , Process
  , RemoteTable
  , SerializableDict
  )

remoteTable :: RemoteTable -> RemoteTable

linkClosure   :: ProcessId -> Closure (Process ())
sendClosure   :: SerializableDict a -> ProcessId -> Closure (a -> Process ())
returnClosure :: SerializableDict a -> a -> Closure (Process a)
