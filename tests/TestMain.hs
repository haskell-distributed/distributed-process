{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import qualified Network.Transport as NT
import Test.Framework
  ( Test
  , defaultMain
  , testGroup
  )
import Network.Transport.TCP
-- import TestGenServer (genServerTests)
import TestTimer (timerTests)
import TestAsync (asyncTests)

tests :: NT.Transport -> TransportInternals -> IO [Test]
tests transport internals = do
  -- gsTestGroup    <- genServerTests transport internals
  asyncTestGroup <- asyncTests transport internals
  timerTestGroup <- timerTests transport internals
  return [
        testGroup "Async"     asyncTestGroup
      , testGroup "Timer"     timerTestGroup ]
     -- , testGroup "GenServer" gsTestGroup ]

main :: IO ()
main = do
  Right (transport, internals) <- createTransportExposeInternals
                                    "127.0.0.1" "8080" defaultTCPParameters
  testData <- tests transport internals
  defaultMain testData
