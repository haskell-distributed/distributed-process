module Main where

import TestTransport 
import Network.Transport.Chan
  
main :: IO ()
main = createTransport >>= testTransport 
