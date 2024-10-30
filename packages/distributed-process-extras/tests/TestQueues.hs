{-# LANGUAGE PatternGuards  #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
module Main where

import qualified Control.Distributed.Process.Extras.Internal.Queue.SeqQ as FIFO
import Control.Distributed.Process.Extras.Internal.Queue.SeqQ ( SeqQ )
import qualified Control.Distributed.Process.Extras.Internal.Queue.PriorityQ as PQ

import Data.Function (on)
import Data.List ( sortBy )
import Test.Framework as TF (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.HUnit (assertBool, assertEqual)

import Prelude


-- NB: these tests/properties are not meant to be complete, but rather
-- they exercise the small number of behaviours that we actually use!

-- TODO: some laziness vs. strictness tests, with error/exception checking

prop_pq_ordering :: [Int] -> Bool
prop_pq_ordering xs =
    let xs' = map (\x -> (x, show x)) xs
        q   = foldl (\q' x -> PQ.enqueue (fst x) (snd x) q') PQ.empty xs'
        ys  = drain q []
        zs  = [snd x | x <- reverse $ sortBy (compare `on` fst) xs']
        -- the sorted list should match the stuff we drained back out
    in zs == ys
  where
    drain q xs'
      | True <- PQ.isEmpty q = xs'
      | otherwise =
          let Just (x, q') = PQ.dequeue q in drain q' (x:xs')

prop_fifo_enqueue :: Int -> Int -> Int -> Bool
prop_fifo_enqueue a b c =
  let q1           = foldl FIFO.enqueue FIFO.empty [a,b,c]
      Just (a', q2) = FIFO.dequeue q1
      Just (b', q3) = FIFO.dequeue q2
      Just (c', q4) = FIFO.dequeue q3
      d             = FIFO.dequeue q4
  in (d == Nothing) && (q4 `seq` [a',b',c'] == [a,b,c])  -- why seq here? to shut the compiler up.

prop_enqueue_empty :: String -> Bool
prop_enqueue_empty s =
  let q            = FIFO.enqueue FIFO.empty s
      Just (_, q') = FIFO.dequeue q
  in (FIFO.isEmpty q') == ((FIFO.isEmpty q) == False)

tests :: [TF.Test]
tests = [
     testGroup "Priority Queue Tests" [
        -- testCase "New Queue Should Be Empty"
        --   (expect (PQ.isEmpty $ PQ.empty) $ equalTo True),
        -- testCase "Singleton Queue Should Contain One Element"
        --   (expect (PQ.dequeue $ (PQ.singleton 1 "hello") :: PriorityQ Int String) $
        --      equalTo $ (Just ("hello", PQ.empty)) :: Maybe (PriorityQ Int String)),
        -- testCase "Dequeue Empty Queue Should Be Nothing"
        --   (expect (Q.isEmpty $ PQ.dequeue $
        --              (PQ.empty :: PriorityQ Int ())) $ equalTo True),
        testProperty "Enqueue/Dequeue should respect Priority order"
            prop_pq_ordering
     ],
     testGroup "FIFO Queue Tests" [
        testCase "New Queue Should Be Empty"
          (assertBool mempty (FIFO.isEmpty $ FIFO.empty)),
        testCase "Singleton Queue Should Contain One Element"
          (assertEqual mempty (FIFO.dequeue $ FIFO.singleton "hello") $ Just ("hello", FIFO.empty)),
        testCase "Dequeue Empty Queue Should Be Nothing"
          (assertEqual mempty  (FIFO.dequeue $ (FIFO.empty :: SeqQ ())) $ (Nothing :: Maybe ((), SeqQ ()))),
        testProperty "Enqueue/Dequeue should respect FIFO order"
            prop_fifo_enqueue,
        testProperty "Enqueue/Dequeue should respect isEmpty"
            prop_enqueue_empty
     ]
   ]

main :: IO ()
main = defaultMain tests

