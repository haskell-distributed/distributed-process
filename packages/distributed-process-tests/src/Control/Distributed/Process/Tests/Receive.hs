{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wall #-}

-- | XXX test doesn't work, because failure exceptions don't get propagated. The
-- test always claims to succeed, even if it failed.

module Control.Distributed.Process.Tests.Receive (tests) where

import Network.Transport.Test (TestTransport(..))

import Network.Transport (Transport)
import Control.Distributed.Process
import Control.Distributed.Process.Node

import Control.Monad

import Test.HUnit (Assertion, (@?=))
import Test.Framework (Test)
import Test.Framework.Providers.HUnit (testCase)

-- Tests:

-- 1. 2 matchChans, receive on each one
-- 2. matchChan/matchIf, receive on each one
-- 3. matchIf/matchChan, receive on each one
-- 4. matchIf/matchChan/matchIf, receive on each one

recTest1 :: ReceivePort ()
         -> SendPort String
         -> ReceivePort String -> ReceivePort String
         -> Process ()
recTest1 wait sync r1 r2 = do
  forever $ do
    receiveChan wait
    r <- receiveWait
      [ matchChan r1       $ \s -> return ("received1 " ++ s)
      , matchChan r2       $ \s -> return ("received2 " ++ s)
      ]
    sendChan sync r

recTest2 :: ReceivePort ()
         -> SendPort String
         -> ReceivePort String -> ReceivePort String
         -> Process ()
recTest2 wait sync r1 _ = do
  forever $ do
    receiveChan wait
    r <- receiveWait
      [ matchChan r1       $ \s -> return ("received1 " ++ s)
      , matchIf (== "foo") $ \s -> return ("received2 " ++ s)
      ]
    sendChan sync r

recTest3 :: ReceivePort ()
         -> SendPort String
         -> ReceivePort String -> ReceivePort String
         -> Process ()
recTest3 wait sync r1 _ = do
  forever $ do
    receiveChan wait
    r <- receiveWait
      [ matchIf (== "foo") $ \s -> return ("received1 " ++ s)
      , matchChan r1       $ \s -> return ("received2 " ++ s)
      ]
    sendChan sync r

recTest4 :: ReceivePort ()
         -> SendPort String
         -> ReceivePort String -> ReceivePort String
         -> Process ()
recTest4 wait sync r1 _ = do
  forever $ do
    receiveChan wait
    r <- receiveWait
      [ matchIf (== "foo") $ \s -> return ("received1 " ++ s)
      , matchChan r1       $ \s -> return ("received2 " ++ s)
      , matchIf (== "bar") $ \s -> return ("received3 " ++ s)
      ]
    sendChan sync r

master :: Process ()
master = do
  (waits,waitr) <- newChan
  (syncs,syncr) <- newChan
  let go expected = do
         sendChan waits ()
         r <- receiveChan syncr
         liftIO $ print (r, expected, r == expected)
         liftIO $ r @?= expected

  liftIO $ putStrLn "---- Test 1 ----"
  (s1,r1) <- newChan
  (s2,r2) <- newChan
  p <- spawnLocal (recTest1 waitr syncs r1 r2)

  sendChan s1 "a" >> go "received1 a"
  sendChan s2 "b" >> go "received2 b"
  sendChan s1 "a" >>  sendChan s2 "b" >>  go "received1 a"
  go "received2 b"

  kill p "BANG"

  liftIO $ putStrLn "\n---- Test 2 ----"
  (s1',r1') <- newChan
  (_  ,r2') <- newChan
  p' <- spawnLocal (recTest2 waitr syncs r1' r2')

  sendChan s1' "a" >> go "received1 a"
  send p' "foo" >> go "received2 foo"
  sendChan s1' "a" >> send p "foo" >> go "received1 a"
  sendChan s1' "a" >> send p "bar" >> go "received1 a"
  go "received2 foo"

  kill p' "BANG"

  liftIO $ putStrLn "\n---- Test 3 ----"
  (s1'',r1'') <- newChan
  (_   ,r2'') <- newChan
  p'' <- spawnLocal (recTest3 waitr syncs r1'' r2'')

  sendChan s1'' "a" >> go "received2 a"
  send p'' "foo" >> go "received1 foo"
  sendChan s1'' "a" >> send p "foo" >> go "received1 foo"
  sendChan s1'' "a" >> send p "bar" >> go "received2 a"
  go "received2 a"

  kill p'' "BANG"

  liftIO $ putStrLn "\n---- Test 4 ----"
  (s1''',r1''') <- newChan
  (_    ,r2''') <- newChan
  p''' <- spawnLocal (recTest4 waitr syncs r1''' r2''')

  sendChan s1''' "a" >> go "received2 a"
  send p''' "foo" >> go "received1 foo"
  send p''' "bar" >> go "received3 bar"
  sendChan s1''' "a" >> send p''' "foo" >> go "received1 foo"
  send p''' "bar" >> go "received2 a"
  send p''' "foo" >> go "received1 foo" >> go "received3 bar"

  kill p''' "BANG"

  terminate

testReceive :: Transport -> RemoteTable -> Assertion
testReceive transport rtable = do
  node <- newLocalNode transport rtable
  runProcess node $ master

tests :: TestTransport -> IO [Test]
tests TestTransport{..} = do
    let rtable = initRemoteTable
    return
        [ testCase "testReceive" (testReceive testTransport rtable) ]
