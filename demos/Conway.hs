{-# LANGUAGE TemplateHaskell, DeriveDataTypeable #-}
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
  ( Backend(findVMs)
  , ProcessPair(ProcessPair)
  , RemoteProcess
  , LocalProcess
  , remoteSend
  , localExpect
  )
import Control.Distributed.Process.Backend.Azure.GenericMain (genericMain) 

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
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable "start" = return $ ProcessPair ($(mkClosure 'conwayStart) ()) echo 
    callable _       = error "callable: unknown"

    spawnable :: String -> IO (RemoteProcess ())
    spawnable _ = error "spawnable: unknown"
