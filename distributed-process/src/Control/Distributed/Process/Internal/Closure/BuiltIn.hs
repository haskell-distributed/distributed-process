{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( remoteTable
  , linkClosure
  ) where

import Control.Distributed.Process (link)
import Control.Distributed.Process.Internal.Types 
  ( ProcessId
  , Closure
  , Process
  , RemoteTable
  )
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkClosure)

remotable ['link]

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

-- | Closure version of 'link'
linkClosure :: ProcessId -> Closure (Process ())
linkClosure = $(mkClosure 'link)
