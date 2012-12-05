{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Main where

import           Control.Applicative
import           Control.Monad
import           Data.Data                            (Data, Typeable)
import qualified Data.Map                             as Map
import           Data.Text                            (Text)
import qualified Data.Text                            as T
import           Data.Time                            (Day (..), LocalTime (..),
                                                       TimeOfDay (..),
                                                       TimeZone (..),
                                                       ZonedTime (..),
                                                       hoursToTimeZone)
import           Test.Framework                       (Test, defaultMain,
                                                       testGroup)
import           Test.Framework.Providers.QuickCheck2 (testProperty)
import           Test.QuickCheck                      (Arbitrary (..), Gen,
                                                       choose)

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
tests (transport, transportInternals) = [
	 testGroup "GenServer" (genServerTests transport)
  ]

main :: IO ()
main = do
  Right transport <- createTransportExposeInternals "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)
