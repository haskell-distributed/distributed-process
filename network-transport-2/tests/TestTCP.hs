module Main where

import TestTransport 
import Network.Transport.TCP
import System.Exit (exitFailure, exitSuccess)
  
main :: IO ()
main = do
  success <- createTransport "127.0.0.1" "8080" >>= testTransport 
  if success then exitSuccess else exitFailure
