module Main where

import Network.Transport.Tests.Multicast
import Network.Transport.InMemory (createTransport)

main :: IO ()
main = createTransport >>= testMulticast
