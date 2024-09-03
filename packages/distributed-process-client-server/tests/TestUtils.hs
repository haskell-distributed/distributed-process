{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TupleSections             #-}

module TestUtils
  ( testMain
  , mkNode
  , waitForExit
  ) where

import Control.Concurrent.MVar
  ( MVar
  , takeMVar
  )

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Extras
import Control.Distributed.Process.Extras.Time
import Control.Distributed.Process.Extras.Timer
import Test.Framework (Test, defaultMain)

import Network.Transport.TCP
import qualified Network.Transport as NT

waitForExit :: MVar ExitReason
            -> Process (Maybe ExitReason)
waitForExit exitReason = do
    -- we *might* end up blocked here, so ensure the test doesn't jam up!
  self <- getSelfPid
  tref <- killAfter (within 10 Seconds) self "testcast timed out"
  tr <- liftIO $ takeMVar exitReason
  cancelTimer tref
  case tr of
    ExitNormal -> return Nothing
    other      -> return $ Just other

mkNode :: String -> IO LocalNode
mkNode port = do
  Right (transport1, _) <- createTransportExposeInternals (defaultTCPAddr "127.0.0.1" port) defaultTCPParameters
  newLocalNode transport1 initRemoteTable

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals (defaultTCPAddr "127.0.0.1" "0") defaultTCPParameters
  testData <- builder transport
  defaultMain testData
