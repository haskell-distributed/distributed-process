-- Run tests using the TCP transport.

module Main where

import TEST_SUITE_MODULE (tests)

import Network.Transport.Test (TestTransport(..))
import Network.Transport.InMemory
import Test.Framework (defaultMainWithArgs)

import System.Environment (getArgs)

main :: IO ()
main = do
    (transport, internals) <- createTransportExposeInternals
    ts <- tests TestTransport
      { testTransport = transport
      , testBreakConnection = \addr1 addr2 -> breakConnection internals addr1 addr2 "user error"
      }
    args <- getArgs
    -- Tests are time sensitive. Running the tests concurrently can slow them
    -- down enough that threads using threadDelay would wake up later than
    -- expected, thus changing the order in which messages were expected.
    -- Therefore we run the tests sequentially by passing "-j 1" to
    -- test-framework. This does not solve the issue but makes it less likely.
    --
    -- The problem was first detected with
    -- 'Control.Distributed.Process.Tests.CH.testMergeChannels'
    -- in particular.
    defaultMainWithArgs ts ("-j" : "1" : args)
