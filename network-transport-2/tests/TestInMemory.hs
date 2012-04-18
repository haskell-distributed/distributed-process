module Main where

import TestTransport 
import Network.Transport.Chan
import System.Exit (exitFailure, exitSuccess)
  
main :: IO ()
main = do
  success <- createTransport >>= testTransport 
  if success then exitSuccess else exitFailure
