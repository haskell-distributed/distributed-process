{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import           Control.Applicative
import           Control.Monad
import           Test.Framework                       (Test, defaultMain,
                                                       testGroup)

import qualified Network.Transport as NT (Transport, closeEndPoint)
import Network.Transport.TCP 
  ( createTransportExposeInternals
  , TransportInternals(socketBetween)
  , defaultTCPParameters
  )
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types 
  ( NodeId(nodeAddress) 
  , LocalNode(localEndPoint)
  )
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (Serializable)

import TestGenServer

tests :: (NT.Transport, TransportInternals)  -> [Test]
tests transportConfig = [
     testGroup "GenServer" (genServerTests transportConfig)
  ]

main :: IO ()
main = do
  Right transport <- createTransportExposeInternals "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)