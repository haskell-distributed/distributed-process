{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

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
main :: IO ()
main = defaultMain tests

tests :: [Test]
tests = []
