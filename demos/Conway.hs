{-# LANGUAGE TemplateHaskell, DeriveDataTypeable #-}
import System.Environment (getArgs)
import Data.Data (Typeable, Data)
import Data.Binary (Binary(get, put))
import Data.Binary.Generic (getGeneric, putGeneric)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Control.Distributed.Process
  ( Process
  , expect
  )
import Control.Distributed.Process.Closure
  ( remotable
  , mkClosure
  )
import Control.Distributed.Process.Backend.Azure 

data ControllerMsg = 
    ControllerExit
  deriving (Typeable, Data)

instance Binary ControllerMsg where
  get = getGeneric
  put = putGeneric

conwayStart :: () -> Backend -> Process ()
conwayStart () backend = do 
  vms <- liftIO $ findVMs backend
  remoteSend (show vms)

remotable ['conwayStart]

echo :: LocalProcess ()
echo = forever $ do
  msg <- localExpect
  liftIO $ putStrLn msg

main :: IO ()
main = do
  args <- getArgs
  case args of
    "onvm":args' -> onVmMain __remoteTable args'
    cmd:sid:x509:pkey:user:cloudService:virtualMachine:port:_ -> do
      params <- defaultAzureParameters sid x509 pkey 
      let params' = params { azureSshUserName = user }
      backend <- initializeBackend params' cloudService
      Just vm <- findNamedVM backend virtualMachine
      case cmd of
        "start" -> callOnVM backend vm port $ 
                      ProcessPair ($(mkClosure 'conwayStart) ()) 
                                  echo  
