{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable #-}
module TestGenServer where

import Data.Binary (Binary(..))
import Data.Typeable (Typeable)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar 
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , readMVar
  )
import Control.Monad (replicateM_, replicateM, forever)
import Control.Exception (SomeException, throwIO)
import qualified Control.Exception as Ex (catch)
import Control.Applicative ((<$>), (<*>), pure, (<|>))
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

import Test.HUnit (Assertion)
import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)

--------------------------------------------------------------------------------
-- The tests proper                                                           --
--------------------------------------------------------------------------------

newtype Ping = Ping ProcessId
  deriving (Typeable, Binary, Show)

newtype Pong = Pong ProcessId
  deriving (Typeable, Binary, Show)

-- | The ping server from the paper
ping :: Process ()
ping = do
  Pong partner <- expect
  self <- getSelfPid
  send partner (Ping self)
  ping

-- | Basic ping test
testPing :: NT.Transport -> Assertion 
testPing transport = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  -- Server
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    addr <- forkProcess localNode ping
    putMVar serverAddr addr

  -- Client
  forkIO $ do
    localNode <- newLocalNode transport initRemoteTable
    pingServer <- readMVar serverAddr

    let numPings = 10000

    runProcess localNode $ do
      pid <- getSelfPid
      replicateM_ numPings $ do
        send pingServer (Pong pid)
        Ping _ <- expect
        return ()

    putMVar clientDone ()

  takeMVar clientDone


genServerTests :: (NT.Transport, TransportInternals) -> [Test]
genServerTests (transport, _) = [
    testGroup "Basic features" [
        testCase "Ping"                (testPing                transport)
      ]
  ]
