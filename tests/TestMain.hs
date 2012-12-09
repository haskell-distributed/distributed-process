{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import 			 System.IO (hSetBuffering, BufferMode(..), stdin, stdout, stderr)
import           Test.Framework          (Test, defaultMain, testGroup)
import qualified Network.Transport as NT
import           Network.Transport.TCP
import           TestGenServer           (genServerTests)
import           TestTimer               (timerTests)

tests :: NT.Transport -> TransportInternals -> IO [Test]
tests transport internals = do
  gsTestGroup    <- genServerTests transport internals
  timerTestGroup <- timerTests     transport internals
  return [
       testGroup "GenServer" gsTestGroup
     , testGroup "Timer"     timerTestGroup ]

main :: IO ()
main = do
  hSetBuffering stdin NoBuffering
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering

  Right (transport, internals) <- createTransportExposeInternals
                                    "127.0.0.1" "8080" defaultTCPParameters
  testData <- tests transport internals
  defaultMain testData
