module Main where

import Network.Transport.Tests
import Network.Transport.Tests.Auxiliary (runTests)
import Network.Transport.Chan
import Network.Transport
import Control.Applicative ((<$>))
import Control.Concurrent

main :: IO ()
main = do
  Right transport <- newTransport
  killTransport <- newTransport
  runTests
    [ ("PingPong",              testPingPong transport numPings)
    , ("EndPoints",             testEndPoints transport numPings)
    , ("Connections",           testConnections transport numPings)
    , ("CloseOneConnection",    testCloseOneConnection transport numPings)
    , ("CloseOneDirection",     testCloseOneDirection transport numPings)
    , ("CloseReopen",           testCloseReopen transport numPings)
    , ("ParallelConnects",      testParallelConnects transport numPings)
    , ("SendAfterClose",        testSendAfterClose transport 100)
    , ("Crossing",              testCrossing transport 10)
    , ("CloseTwice",            testCloseTwice transport 100)
    , ("ConnectToSelf",         testConnectToSelf transport numPings)
    , ("ConnectToSelfTwice",    testConnectToSelfTwice transport numPings)
    , ("CloseSelf",             testCloseSelf newTransport)
    , ("CloseEndPoint",         testCloseEndPoint transport numPings)
    -- XXX: require transport communication
    -- ("CloseTransport",        testCloseTransport newTransport)
    , ("ConnectClosedEndPoint", testConnectClosedEndPoint transport)
    , ("ExceptionOnReceive",    testExceptionOnReceive newTransport)
    , ("SendException",         testSendException newTransport)
    , ("Kill",                  testKill (return killTransport) 1000)
    ]
  closeTransport transport
  where
    numPings = 10000 :: Int
    newTransport = Right <$> createTransport
