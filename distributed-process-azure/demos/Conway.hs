{-# LANGUAGE TemplateHaskell, DeriveDataTypeable #-}
import Data.Data (Typeable, Data)
import Data.Binary (Binary(get, put))
import Data.Binary.Generic (getGeneric, putGeneric)
import Control.Distributed.Process
  ( Process
  , Closure
  , expect
  )
import Control.Distributed.Process.Closure
  ( remotable
  , mkClosure
  )
import Control.Distributed.Process.Backend.Azure (Backend)
import Control.Distributed.Process.Backend.Azure.GenericMain 
  ( genericMain
  , ProcessPair(..)
  , RemoteProcess
  )

data ControllerMsg = 
    ControllerExit
  deriving (Typeable, Data)

instance Binary ControllerMsg where
  get = getGeneric
  put = putGeneric

conwayController :: () -> Backend -> Process ()
conwayController () _backend = go
  where
    go = do
      msg <- expect
      case msg of
        ControllerExit -> 
          return ()

remotable ['conwayController]

main :: IO ()
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable _      = error "spawnable: unknown"

    spawnable :: String -> IO (RemoteProcess ())
    spawnable "controller" = return $ $(mkClosure 'conwayController) ()
    spawnable _            = error "callable: unknown"
