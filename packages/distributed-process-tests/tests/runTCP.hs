-- Run tests using the TCP transport.
--
module Main where

import TEST_SUITE_MODULE (tests)

import Network.Transport.Test (TestTransport(..))
import Network.Socket (close)
import Network.Transport.TCP
  ( createTransportExposeInternals
  , TransportInternals(socketBetween)
  , defaultTCPParameters
  , defaultTCPAddr
  , TCPParameters(..)
  )
import Test.Tasty (defaultMain, localOption)
import Test.Tasty.Runners (NumThreads)

import Control.Concurrent (threadDelay)
import Control.Exception  (IOException, try)
import System.IO

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    Right (transport, internals) <-
      createTransportExposeInternals (defaultTCPAddr "127.0.0.1" "0")
        defaultTCPParameters { transportConnectTimeout = Just 3000000 }
    ts <- tests TestTransport
      { testTransport = transport
      , testBreakConnection = \addr1 addr2 -> do
          esock <- try $ socketBetween internals addr1 addr2
          either (\e -> const (return ()) (e :: IOException)) close esock
          threadDelay 10000
      }
    -- Tests are time sensitive. Running the tests concurrently can slow them
    -- down enough that threads using threadDelay would wake up later than
    -- expected, thus changing the order in which messages were expected.
    -- Therefore we run the tests sequentially
    --
    -- The problem was first detected with
    -- 'Control.Distributed.Process.Tests.CH.testMergeChannels'
    -- in particular.
    defaultMain (localOption (1::NumThreads) ts)
