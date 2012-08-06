{-# LANGUAGE TemplateHaskell #-}
import Control.Distributed.Process
  ( Process
  , Closure
  )
import Control.Distributed.Process.Closure
  ( remotable )
import Control.Distributed.Process.Backend.Azure.GenericMain 
  ( genericMain
  , ProcessPair(..)
  )

remotable []

main :: IO ()
main = genericMain __remoteTable callable spawnable
  where
    callable :: String -> IO (ProcessPair ())
    callable _      = error "spawnable: unknown"

    spawnable :: String -> IO (Closure (Process ()))
    spawnable _            = error "callable: unknown"
