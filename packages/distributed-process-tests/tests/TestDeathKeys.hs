module Main where

import Control.Distributed.Process.Internal.BiMultiMap (BiMultiMap)
import qualified Control.Distributed.Process.Internal.BiMultiMap as BiMultiMap
import Control.Distributed.Process.Internal.Messaging
  ( deathKey
  , deathKeys
  , impliesDeathOf
  )
import Control.Distributed.Process.Internal.Types
  ( Identifier(..)
  , LocalProcessId(..)
  , NodeId(..)
  , ProcessId(..)
  , SendPortId(..)
  )
import qualified Data.ByteString.Char8 as BSC
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import Network.Transport (EndPointAddress(..))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.QuickCheck
  ( Arbitrary(..)
  , Positive(..)
  , elements
  , testProperty
  )

-- All identifiers with 2 nodes, 4 processes per node and 2 ports per process.
universe :: [Identifier]
universe = map NodeIdentifier nodes
        ++ map ProcessIdentifier processes
        ++ [ SendPortIdentifier (SendPortId pid c) | pid <- processes, c <- [0, 1] ]
  where
    nodes = [ NodeId (EndPointAddress (BSC.pack a)) | a <- ["a", "b"] ]
    processes = [ ProcessId nid (LocalProcessId u c)
                | nid <- nodes, u <- [0, 1], c <- [0, 1] ]

newtype Ident = Ident Identifier

instance Show Ident where
  show (Ident i) = show i

instance Arbitrary Ident where
  arbitrary = Ident <$> elements universe

testDeathKeyImpliesDeathOf :: TestTree
testDeathKeyImpliesDeathOf =
  testCase "deathKey agrees with impliesDeathOf" $
    assertEqual "counterexamples" []
      [ (a, b) | a <- universe, b <- universe
               , (a `impliesDeathOf` b) /= (deathKey a b `elem` deathKeys a) ]

testDeathKeyMonotone :: TestTree
testDeathKeyMonotone =
  testCase "deathKey is monotone" $
    assertEqual "counterexamples" []
      [ (a, b1, b2) | a <- universe, b1 <- universe, b2 <- universe
                    , b1 <= b2, deathKey a b1 > deathKey a b2 ]

-- Projections on Int: @(`div` d)@ is monotone.
prop_partitionOn :: Positive Int -> [Int] -> Map Int Char -> Bool
prop_partitionOn (Positive d) ps m =
  BiMultiMap.partitionOn (`div` d) ps m
    == Map.partitionWithKey (\k _ -> (k `div` d) `elem` ps) m

prop_partitionOnDeathKey :: Ident -> [(Ident, Char)] -> Bool
prop_partitionOnDeathKey (Ident a) kvs =
  BiMultiMap.partitionOn (deathKey a) (deathKeys a) m
    == Map.partitionWithKey (\k _ -> a `impliesDeathOf` k) m
  where
    m = Map.fromList [ (k, v) | (Ident k, v) <- kvs ]

prop_partitionOnBy1st :: Positive Int -> [Int] -> [(Int, Int, Char)] -> Bool
prop_partitionOnBy1st (Positive d) ps ts =
  sameResult (BiMultiMap.partitionOnBy1st (`div` d) ps bm)
             (BiMultiMap.partitionWithKeyBy1st (\k _ -> (k `div` d) `elem` ps) bm)
  where
    bm = fromTriplets ts

prop_partitionOnBy2nd :: Positive Int -> [Int] -> [(Int, Int, Char)] -> Bool
prop_partitionOnBy2nd (Positive d) ps ts =
  sameResult (BiMultiMap.partitionOnBy2nd (`div` d) ps bm)
             (BiMultiMap.partitionWithKeyBy2nd (\k _ -> (k `div` d) `elem` ps) bm)
  where
    bm = fromTriplets ts

sameResult :: (Eq k, Eq s)
           => (Map k s, BiMultiMap Int Int Char)
           -> (Map k s, BiMultiMap Int Int Char)
           -> Bool
sameResult (m, bm) (m', bm') = m == m' && sides bm == sides bm'

fromTriplets :: [(Int, Int, Char)] -> BiMultiMap Int Int Char
fromTriplets = foldr (\(a, b, v) -> BiMultiMap.insert a b v) BiMultiMap.empty

-- Both sides of a multimap: by the first and by the second component.
sides :: BiMultiMap Int Int Char
      -> (Map Int (Set (Int, Char)), Map Int (Set (Int, Char)))
sides bm = ( fst (BiMultiMap.partitionWithKeyBy1st (\_ _ -> True) bm)
           , fst (BiMultiMap.partitionWithKeyBy2nd (\_ _ -> True) bm)
           )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Death keys"
  [ testDeathKeyImpliesDeathOf
  , testDeathKeyMonotone
  , testProperty "partitionOn" prop_partitionOn
  , testProperty "partitionOn with deathKey" prop_partitionOnDeathKey
  , testProperty "partitionOnBy1st" prop_partitionOnBy1st
  , testProperty "partitionOnBy2nd" prop_partitionOnBy2nd
  ]
