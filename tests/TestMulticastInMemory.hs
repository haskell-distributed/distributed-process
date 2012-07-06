module Main where

import TestMulticast
import Network.Transport.Chan (createTransport)

main :: IO ()
main = createTransport >>= testMulticast
