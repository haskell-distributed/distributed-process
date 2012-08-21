{-# LANGUAGE TemplateHaskell #-}

import System.IO (hFlush, stdout)
import System.Environment (getArgs)
import Control.Monad (unless, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process (Process, expect)
import Control.Distributed.Process.Closure (remotable, mkClosure) 
import Control.Distributed.Process.Backend.Azure 

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
main = do
  args <- getArgs
  case args of
    "onvm":args' -> onVmMain __remoteTable args'
    sid:x509:pkey:user:cloudService:virtualMachine:port:_ -> do
      params <- defaultAzureParameters sid x509 pkey 
      let params' = params { azureSshUserName = user }
      backend <- initializeBackend params' cloudService
      Just vm <- findNamedVM backend virtualMachine
      callOnVM backend vm port $
        ProcessPair ($(mkClosure 'echoRemote) ()) 
                    echoLocal 
