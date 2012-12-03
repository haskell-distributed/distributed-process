module Main where

import Network.Transport.Tests
import Network.Transport.Chan
import Control.Applicative ((<$>))

main :: IO ()
main = testTransport (Right <$> createTransport)
