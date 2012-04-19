module Main where

import TestMulticast
import Network.Transport.Chan
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  success <- createTransport >>= testMulticast
  if success then exitSuccess else exitFailure
