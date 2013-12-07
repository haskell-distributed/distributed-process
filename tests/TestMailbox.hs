{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import qualified Control.Exception as E (SomeException)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform
  ( Addressable(..)
  )

import qualified Control.Distributed.Process.Platform (__remoteTable)
import Control.Distributed.Process.Platform.Mailbox
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer (sleep)
import Control.Distributed.Process.Serializable
import Control.Monad (void, forM_, forM)
import Control.Rematch
  ( equalTo
  )

import qualified Data.Foldable as Foldable
import qualified Data.List as List
-- import Data.Sequence
import qualified Data.Sequence as Seq

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop)
#endif

import Control.Rematch hiding (on, expect, match)
import qualified Control.Rematch as Rematch
import Control.Rematch.Run
import Data.Foldable (Foldable)
import qualified Data.Foldable as Foldable
import Data.Function (on)
import Data.List hiding (drop)
import Data.Maybe (fromJust, catMaybes)
import Debug.Trace
import Control.Distributed.Process.Closure (remotable, mkClosure)

import Test.HUnit.Base (assertBool)
import Test.Framework as TF (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit
-- import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.HUnit (Assertion, assertFailure)
import TestUtils
import qualified MailboxTestFilters (__remoteTable)
import MailboxTestFilters (myFilter)

import qualified Network.Transport as NT

allBuffersShouldRespectFIFOOrdering :: BufferType -> TestResult Bool -> Process ()
allBuffersShouldRespectFIFOOrdering buffT result = do
  let [a, b, c] = ["a", "b", "c"]
  mbox <- createAndSend buffT [a, b, c]
  active mbox acceptEverything
  Just Delivery{ messages = msgs } <- receiveTimeout (after 2 Seconds) [ match return ]
  let [ma', mb', mc'] = msgs
  Just a' <- unwrapMessage ma' :: Process (Maybe String)
  Just b' <- unwrapMessage mb' :: Process (Maybe String)
  Just c' <- unwrapMessage mc' :: Process (Maybe String)
  let values = [a', b', c']
  stash result $ values == [a, b, c]

resizeShouldRespectOrdering :: BufferType
           -> TestResult [String]
           -> Process ()
resizeShouldRespectOrdering buffT result = do
  let [a, b, c, d, e] = ["a", "b", "c", "d", "e"]
  mbox <- createAndSend buffT [a, b, c, d, e]
  resize mbox (3 :: Integer)

  active mbox acceptEverything
  Just Delivery{ messages = msgs } <- receiveTimeout (after 2 Seconds) [ match return ]

  let [mc', md', me'] = msgs
  Just c' <- unwrapMessage mc' :: Process (Maybe String)
  Just d' <- unwrapMessage md' :: Process (Maybe String)
  Just e' <- unwrapMessage me' :: Process (Maybe String)
  let values = [c', d', e']
  stash result $ values

bufferLimiting :: BufferType -> TestResult (Integer, [Maybe String]) -> Process ()
bufferLimiting buffT result = do
  let msgs = ["a", "b", "c", "d", "e", "f", "g"]
  mbox <- createMailboxAndPost buffT 4 msgs

  MailboxStats{ pendingMessages = pending'
              , droppedMessages = dropped'
              , currentLimit    = limit' } <- statistics mbox
  pending' `shouldBe` equalTo 4
  dropped' `shouldBe` equalTo 3
  limit'   `shouldBe` equalTo 4

  active mbox acceptEverything
  Just Delivery{ messages = recvd
               , totalDropped = skipped } <- receiveTimeout (after 5 Seconds)
                                                            [ match return ]
  seen <- mapM unwrapMessage recvd
  stash result (skipped, seen)

mailboxIsInitiallyPassive :: TestResult Bool -> Process ()
mailboxIsInitiallyPassive result = do
  mbox <- createMailbox Stack (6 :: Integer)
  mapM_ (post mbox) ([1..5] :: [Int])
  Nothing <- receiveTimeout (after 3 Seconds) [ matchAny return ]
  notify mbox
  inbound <- receiveTimeout (after 3 Seconds) [ match return ]
  case inbound of
    Just (NewMail _) -> stash result True
    Nothing          -> stash result False

mailboxActsAsRelayForRawTraffic :: TestResult Bool -> Process ()
mailboxActsAsRelayForRawTraffic result = do
  mbox <- createMailbox Stack (6 :: Integer)
  mapM_ (sendTo mbox) ([1..5] :: [Int])
  forM_ [1..5] $ \(_ :: Int) -> do
    i <- receiveTimeout (after 3 Seconds) [ match return ]
    case i of
      Nothing         -> stash result False >> die "failed!"
      Just (_ :: Int) -> return ()
  stash result True

createAndSend :: BufferType -> [String] -> Process Mailbox
createAndSend buffT msgs = createMailboxAndPost buffT 10 msgs

createMailboxAndPost :: BufferType -> Limit -> [String] -> Process Mailbox
createMailboxAndPost buffT maxSz msgs = do
  (cc, cp) <- newChan
  mbox <- createMailbox buffT maxSz
  spawnLocal $ mapM_ (post mbox) msgs >> sendChan cc ()
  () <- receiveChan cp
  return mbox

complexMailboxFiltering :: (String, Int, Bool)
                        -> TestResult (String, Int, Bool)
                        -> Process ()
complexMailboxFiltering inputs@(s', i', b') result = do
  mbox <- createMailbox Stack (10 :: Integer)
  post mbox s'
  post mbox i'
  post mbox b'

  active mbox $ myFilter inputs
  Just Delivery{ messages = [m1, m2, m3]
               , totalDropped = skipped } <- receiveTimeout (after 5 Seconds)
                                                            [ match return ]
  Just s <- unwrapMessage m1 :: Process (Maybe String)
  Just i <- unwrapMessage m2 :: Process (Maybe Int)
  Just b <- unwrapMessage m3 :: Process (Maybe Bool)
  stash result $ (s, i, b)

myRemoteTable :: RemoteTable
myRemoteTable =
  Control.Distributed.Process.Platform.__remoteTable $
  MailboxTestFilters.__remoteTable initRemoteTable

tests :: NT.Transport  -> IO [Test]
tests transport = do
  {- verboseCheckWithResult stdArgs -}
  localNode <- newLocalNode transport myRemoteTable
  return [
        testGroup "Dequeue/Pop Ordering"
        [
          testCase "Queue Ordering"
          (delayedAssertion
           "Expected the Queue to offer FIFO ordering"
           localNode True (allBuffersShouldRespectFIFOOrdering Queue))
        , testCase "Stack Ordering"
          (delayedAssertion
           "Expected the Queue to offer FIFO ordering"
           localNode True (allBuffersShouldRespectFIFOOrdering Stack))
        , testCase "Ring Ordering"
           (delayedAssertion
            "Expected the Queue to offer FIFO ordering"
            localNode True (allBuffersShouldRespectFIFOOrdering Ring))
        ]
      , testGroup "Resize & Ordering"
        [
          testCase "Queue Drops Eldest"
          (delayedAssertion
           "expected c, d, e"
           localNode ["c", "d", "e"] $ resizeShouldRespectOrdering Queue)
        , testCase "Stack Drops Youngest"
          (delayedAssertion
           "expected a, b, c"
           localNode ["a", "b", "c"] $ resizeShouldRespectOrdering Stack)
        , testCase "Ring Drops Youngest"
          (delayedAssertion
           "expected a, b, c"
           localNode ["a", "b", "c"] $ resizeShouldRespectOrdering Ring)
        ]
      , testGroup "Buffer Limits & Discarded Messages"
        [
          testCase "Queue Drops Eldest and Enqueues New"
          (delayedAssertion
           "expected d, e, f, g"
           localNode ((3 :: Integer), map Just ["d", "e", "f", "g"]) $ bufferLimiting Queue)
        , testCase "Stack Drops Youngest And Pushes New"
          (delayedAssertion
           "expected a, b, c, g"
           localNode ((3 :: Integer), map Just ["a", "b", "c", "g"]) $ bufferLimiting Stack)
        , testCase "Ring Rejects New Entries"
          (delayedAssertion
           "expected a, b, c, d"
           localNode ((3 :: Integer), map Just ["a", "b", "c", "d"]) $ bufferLimiting Ring)
        ]
      , testGroup "Notify & Activation"
        [
          testCase "Mailbox is initially Passive"
           (delayedAssertion
            "Expected the Mailbox to remain passive until told otherwise"
            localNode True mailboxIsInitiallyPassive)
        , testCase "Mailbox Relays Raw (Un-Posted) Traffic"
           (delayedAssertion
            "Expected traffic to be relayed directly to us"
            localNode True mailboxActsAsRelayForRawTraffic)
        , testCase "Complex Filtering Rules"
           (delayedAssertion
            "Expected the relevant filters to accept our data"
            localNode inputs (complexMailboxFiltering inputs))
        ]
    ]
  where
    inputs = ("hello", 10 :: Int, True)

main :: IO ()
main = testMain $ tests

