{-# LANGUAGE TemplateHaskell #-}

import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process (Process, ProcessId, getSelfPid)
import Control.Distributed.Process.Closure (remotable, mkClosure, sdictProcessId)
import Control.Distributed.Process.Backend.Azure.GenericMain 
  ( genericMain
  , ProcessPair(..)
  )

getPid :: () -> Process ProcessId
getPid () = getSelfPid

remotable ['getPid]

main = genericMain __remoteTable $ \cmd ->
  case cmd of
    "hello" -> return $ ProcessPair ($(mkClosure 'getPid) ()) print sdictProcessId
    _       -> error "unknown command"
