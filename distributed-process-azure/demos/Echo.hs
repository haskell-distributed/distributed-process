{-# LANGUAGE TemplateHaskell #-}

import System.IO (hFlush, stdout)
import Control.Monad (unless, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process (Process, expect)
import Control.Distributed.Process.Closure (remotable, mkClosure) 
import Control.Distributed.Process.Backend.Azure 
  ( Backend
  , ProcessPair(..)
  , RemoteProcess
  , LocalProcess
  , localExpect
  , remoteSend
  , localSend
  )
import Control.Distributed.Process.Backend.Azure.GenericMain (genericMain) 

echoRemote :: () -> Backend -> Process ()
echoRemote () _backend = forever $ do
  str <- expect 
  remoteSend (str :: String)

remotable ['echoRemote]

echoLocal :: LocalProcess ()
echoLocal = do
  str <- liftIO $ putStr "# " >> hFlush stdout >> getLine
  unless (null str) $ do
    localSend str
    liftIO $ putStr "Echo: " >> hFlush stdout
    echo <- localExpect
    liftIO $ putStrLn echo
    echoLocal

main :: IO ()
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable "echo" = return $ ProcessPair ($(mkClosure 'echoRemote) ()) echoLocal 
    callable _      = error "callable: unknown"

    spawnable :: String -> IO (RemoteProcess ())
    spawnable _ = error "spawnable: unknown"
