{-# LANGUAGE LambdaCase #-}

-- Run tests using the QUIC transport.
--
module Main where

import Control.Distributed.Process.Tests.CH (tests)
import Control.Exception (bracket, throwIO)
import Data.List.NonEmpty (NonEmpty (..))
import Network.Transport (Transport, closeTransport)
import Network.Transport.QUIC
  ( QUICTransportConfig (..),
    createTransport,
    credentialLoadX509,
  )
import Network.Transport.Test (TestTransport (..))
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering),
    hSetBuffering,
    stderr,
    stdout,
  )
import Test.Tasty (defaultMain, localOption)
import Test.Tasty.Runners (NumThreads)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  withQUICTransport $ \transport -> do
    ts <-
      tests
        TestTransport
          { testTransport = transport,
            testBreakConnection = \_ _ -> pure () -- I'm not sure how to break the connection at this time
          }

    -- Tests are time sensitive. Running the tests concurrently can slow them
    -- down enough that threads using threadDelay would wake up later than
    -- expected, thus changing the order in which messages were expected.
    -- Therefore we run the tests sequentially
    --
    -- The problem was first detected with
    -- 'Control.Distributed.Process.Tests.CH.testMergeChannels'
    -- in particular.
    defaultMain (localOption (1 :: NumThreads) ts)

withQUICTransport :: (Transport -> IO a) -> IO a
withQUICTransport =
  bracket
    (mkQUICTransport >>= either (throwIO . userError) pure)
    closeTransport

mkQUICTransport :: IO (Either String Transport)
mkQUICTransport = do
  credentialLoadX509
    -- Generate a self-signed x509v3 certificate using this nifty tool:
    -- https://certificatetools.com/
    ("tests" </> "credentials" </> "cert.crt")
    ("tests" </> "credentials" </> "cert.key")
    >>= \case
      Left errmsg -> pure $ Left errmsg
      Right creds ->
        Right
          <$> createTransport
            ( QUICTransportConfig
                { hostName = "127.0.0.1",
                  serviceName = "0",
                  credentials = creds :| [],
                  -- credentials are self-signed, and therefore cannot be validated
                  validateCredentials = False
                }
            )
