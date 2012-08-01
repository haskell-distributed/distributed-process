{-# LANGUAGE TemplateHaskell #-}

import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process (Process)
import Control.Distributed.Process.Closure (remotable, mkClosure)
import Control.Distributed.Process.Backend.Azure.GenericMain (genericMain) 

cprint :: String -> Process ()
cprint = liftIO . putStrLn

remotable ['cprint]

main = genericMain __remoteTable $ \cmd ->
  case cmd of
    "hello" -> return $ $(mkClosure 'cprint) "Hi world!"
    _       -> error "unknown command"
