module Main where

import Network.Transport.Tests.Multicast
import Network.Transport.Chan (createTransport)

main :: IO ()
main = createTransport >>= testMulticast
