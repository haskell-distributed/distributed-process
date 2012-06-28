module Control.Distributed.Process.Internal.Closure.BuiltIn where 

import Control.Distributed.Process.Internal.Types 
  ( ProcessId
  , Closure
  , Process
  , RemoteTable
  )

remoteTable :: RemoteTable -> RemoteTable

linkClosure :: ProcessId -> Closure (Process ())
