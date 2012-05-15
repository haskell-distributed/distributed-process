module Main where

import TestTransport 
import Network.Transport.Chan
import Control.Applicative ((<$>))
  
main :: IO ()
main = testTransport (Right <$> createTransport)
