{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell    #-}
module TestGenServer where

import Data.Binary (Binary (..))
import Data.Typeable (Typeable)
import Data.DeriveTH
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
  ( newEmptyMVar
  , putMVar
  , takeMVar
  )
import qualified Network.Transport as NT (Transport)
import Network.Transport.TCP (TransportInternals)
import Control.Distributed.Process.Internal.Types()
import Control.Distributed.Process (say, liftIO, exit)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable()

import Test.HUnit (Assertion)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.HUnit (testCase)

import Control.Distributed.Platform.GenServer
import Control.Distributed.Platform.Internal.Types
import GenServer.Counter
import GenServer.Kitty

--------------------------------------------------------------------------------
-- The tests proper                                                           --
--------------------------------------------------------------------------------

data Ping = Ping
  deriving (Typeable, Show)
$(derive makeBinary ''Ping)

data Pong = Pong
  deriving (Typeable, Show)
$(derive makeBinary ''Pong)


-- | Test ping server
-- TODO fix this test!
testPing :: NT.Transport -> Assertion
testPing transport = do
  initDone <- newEmptyMVar
  pingDone <- newEmptyMVar
  pongDone <- newEmptyMVar
  terminateDone <- newEmptyMVar
  serverAddr <- newEmptyMVar

  localNode <- newLocalNode transport initRemoteTable

  forkIO $ runProcess localNode $ do
      say "Starting ..."
      sid <- start (0 :: Int) defaultServer {
          initHandler       = do
            --trace "Init ..."
            c <- getState
            liftIO $ putMVar initDone c
            initOk Infinity,
          terminateHandler = \_ -> do
            --trace "Terminate ..."
            c <- getState
            liftIO $ putMVar terminateDone c
            return (),
          handlers          = [
            handle (\Ping -> do
              --trace "Ping ..."
              modifyState (+1)
              c <- getState
              liftIO $ putMVar pingDone c
              ok Pong),
            handle (\Pong -> do
              --trace "Pong ..."
              modifyState (1 +)
              c <- getState
              liftIO $ putMVar pongDone c
              ok ())
        ]}
      liftIO $ putMVar serverAddr sid
      return ()

  forkIO $ runProcess localNode $ do
      sid <- liftIO $ takeMVar serverAddr

      liftIO $ takeMVar initDone
      --replicateM_ 10 $ do
      Just Pong <- callTimeout sid (Timeout (TimeInterval Seconds 10)) Ping
      liftIO $ takeMVar pingDone
      cast sid Pong
      liftIO $ takeMVar pongDone
      exit sid ()

  liftIO $ takeMVar terminateDone
  return ()



-- | Test counter server
-- TODO split me!
testCounter :: NT.Transport -> Assertion
testCounter transport = do
  serverDone <- newEmptyMVar

  localNode <- newLocalNode transport initRemoteTable

  runProcess localNode $ do
    cid <- startCounter 0
    _ <- getCount cid
    incCount cid
    incCount cid
    _ <- getCount cid
    resetCount cid
    _ <- getCount cid
    terminateCounter cid
    liftIO $ putMVar serverDone True
    return ()

  liftIO $ takeMVar serverDone
  return ()


-- | Test kitty server
-- TODO split me!
testKitty :: NT.Transport -> Assertion
testKitty transport = do
  serverDone <- newEmptyMVar

  localNode <- newLocalNode transport initRemoteTable

  runProcess localNode $ do
      kPid <- startKitty [Cat "c1" "black" "a black cat"]
      --replicateM_ 100 $ do
      cat1 <- orderCat kPid "c1" "black" "a black cat"
      cat2 <- orderCat kPid "c2" "black" "a black cat"
      returnCat kPid cat1
      returnCat kPid cat2
      closeShop kPid
      terminateKitty kPid
      liftIO $ putMVar serverDone True
      return ()

  liftIO $ takeMVar serverDone
  return ()



tests :: NT.Transport -> [Test]
tests transport = [
    testGroup "Basic features" [
        testCase "Counter"    (testCounter transport),
        testCase "Kitty"      (testKitty transport),
        testCase "Ping"       (testPing transport)
      ]
  ]

genServerTests :: NT.Transport -> TransportInternals -> IO [Test]
genServerTests transport _ = do
  return (tests transport)
