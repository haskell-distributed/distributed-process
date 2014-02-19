{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Distributed.Process hiding (monitor)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Platform
  ( Resolvable(..)
  )

import qualified Control.Distributed.Process.Platform (__remoteTable)
import Control.Distributed.Process.Platform.Execution.Mailbox
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time
import Control.Distributed.Process.Platform.Timer
import Control.Monad (forM_)

import Control.Rematch (equalTo)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop)
#endif

import Data.Maybe (catMaybes)

import Test.Framework as TF (testGroup, Test)
import Test.Framework.Providers.HUnit
import TestUtils
import qualified MailboxTestFilters (__remoteTable)
import MailboxTestFilters (myFilter, intFilter)

import qualified Network.Transport as NT

-- TODO: This whole test suite would be much better off using QuickCheck.
-- The test-framework driver however, doesn't have the API support we'd need
-- to wire in our tests, so we'll have to write a compatibility layer.
-- That should probably go into (or beneath) the C.D.P.P.Test module.

allBuffersShouldRespectFIFOOrdering :: BufferType -> TestResult Bool -> Process ()
allBuffersShouldRespectFIFOOrdering buffT result = do
  let [a, b, c] = ["a", "b", "c"]
  mbox <- createAndSend buffT [a, b, c]
  active mbox acceptEverything
  Just Delivery { messages = msgs } <- receiveTimeout (after 2 Seconds)
                                                         [ match return ]
  let [ma', mb', mc'] = msgs
  Just a' <- unwrapMessage ma' :: Process (Maybe String)
  Just b' <- unwrapMessage mb' :: Process (Maybe String)
  Just c' <- unwrapMessage mc' :: Process (Maybe String)
  let values = [a', b', c']
  stash result $ values == [a, b, c]
--  if values /= [a, b, c]
--     then liftIO $ putStrLn $ "unexpected " ++ ((show buffT) ++ (" values: " ++ (show values)))
--     else return ()

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
    Just (NewMail _ _) -> stash result True
    Nothing            -> stash result False

complexMailboxFiltering :: (String, Int, Bool)
                        -> TestResult (String, Int, Bool)
                        -> Process ()
complexMailboxFiltering inputs@(s', i', b') result = do
  mbox <- createMailbox Stack (10 :: Integer)
  post mbox s'
  post mbox i'
  post mbox b'
  waitForMailboxReady mbox 3

  active mbox $ myFilter inputs
  Just Delivery{ messages = [m1, m2, m3]
               , totalDropped = _ } <- receiveTimeout (after 5 Seconds)
                                                      [ match return ]
  Just s <- unwrapMessage m1 :: Process (Maybe String)
  Just i <- unwrapMessage m2 :: Process (Maybe Int)
  Just b <- unwrapMessage m3 :: Process (Maybe Bool)
  stash result $ (s, i, b)

dropDuringFiltering :: TestResult Bool -> Process ()
dropDuringFiltering result = do
  let rng = [1..50] :: [Int]
  mbox <- createMailbox Stack (50 :: Integer)
  mapM_ (post mbox) rng

  waitForMailboxReady mbox 50
  active mbox $ intFilter

  Just Delivery{ messages = msgs } <- receiveTimeout (after 5 Seconds)
                                                     [ match return ]
  seen <- mapM unwrapMessage msgs
  stash result $ (catMaybes seen) == (filter even rng)

mailboxHandleReUse :: TestResult Bool -> Process ()
mailboxHandleReUse result = do
  mbox <- createMailbox Queue (1 :: Limit)
  post mbox "abc"

  notify mbox
  Just (NewMail mbox' _) <- receiveTimeout (after 2 Seconds)
                                           [ match return ]
  deliver mbox'
  _ <- expect :: Process Delivery
  stash result True

createAndSend :: BufferType -> [String] -> Process Mailbox
createAndSend buffT msgs = createMailboxAndPost buffT 10 msgs

createMailboxAndPost :: BufferType -> Limit -> [String] -> Process Mailbox
createMailboxAndPost buffT maxSz msgs = do
  (cc, cp) <- newChan
  mbox <- createMailbox buffT maxSz
  spawnLocal $ mapM_ (post mbox) msgs >> sendChan cc ()
  () <- receiveChan cp
  waitForMailboxReady mbox $ min (toInteger (length msgs)) maxSz
  return mbox

waitForMailboxReady :: Mailbox -> Integer -> Process ()
waitForMailboxReady mbox sz = do
  sleep $ seconds 1
  notify mbox
  m <- receiveWait [
            matchIf (\(NewMail mbox' sz') -> mbox == mbox' && sz' >= sz)
                    (\_ -> return True)
          , match (\(NewMail _ _) -> return False)
          , matchAny (\_ -> return False)
          ]
  case m of
    True  -> return ()
    False -> waitForMailboxReady mbox sz

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
      , testGroup "Notification, Activation and Delivery"
        [
          testCase "Mailbox is initially Passive"
           (delayedAssertion
            "Expected the Mailbox to remain passive until told otherwise"
            localNode True mailboxIsInitiallyPassive)
        , testCase "Mailbox Notifications include usable control channel"
           (delayedAssertion
            "Expected traffic to be relayed directly to us"
            localNode True mailboxHandleReUse)
        , testCase "Complex Filtering Rules"
           (delayedAssertion
            "Expected the relevant filters to accept our data"
            localNode inputs (complexMailboxFiltering inputs))
        , testCase "Filter out unwanted messages"
           (delayedAssertion
            "Expected only even numbers to be sent delivered"
            localNode True dropDuringFiltering)
        ]
    ]
  where
    inputs = ("hello", 10 :: Int, True)

main :: IO ()
main = testMain $ tests

