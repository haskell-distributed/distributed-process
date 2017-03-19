{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}

module Main where

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Extras
 ( ExitReason(..)
 , isProcessAlive
 )
import qualified Control.Distributed.Process.Extras (__remoteTable)
import Control.Distributed.Process.Extras.Time hiding (timeout)
import Control.Distributed.Process.Extras.Timer
import Control.Distributed.Process.FSM
import Control.Distributed.Process.FSM.Internal.Process
import Control.Distributed.Process.FSM.Internal.Types hiding (State, liftIO)
import qualified Control.Distributed.Process.FSM.Internal.Types as FSM
import Control.Distributed.Process.SysTest.Utils

import Control.Rematch (equalTo)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop)
#endif

import Data.Maybe (catMaybes)

import Test.Framework as TF (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit

import Network.Transport.TCP
import qualified Network.Transport as NT

-- import Control.Distributed.Process.Serializable (Serializable)
-- import Control.Monad (void)
import Data.Binary (Binary)
import Data.Typeable (Typeable)
import GHC.Generics

data State = On | Off deriving (Eq, Show, Typeable, Generic)
instance Binary State where

data Reset = Reset deriving (Eq, Show, Typeable, Generic)
instance Binary Reset where

data Check = Check deriving (Eq, Show, Typeable, Generic)
instance Binary Check where

type StateData = Integer
type ButtonPush = ()
type Stop = ExitReason

initCount :: StateData
initCount = 0

startState :: Step State Integer
startState = initState Off initCount

-- TODO: [LANG] it's great that we can filter on StateID per event,
-- but we also need a way to specify that certain events are only handled
-- in specific states (e.g. to utilise `become` in the ManagedProcess API)

switchFsm :: Step State StateData
switchFsm = startState
         ^. ((event :: Event ButtonPush)
              ~> (  (On  ~@ (set (+1) >> enter Off)) -- on => off => on is possible with |> here...
                 .| (Off ~@ (set (+1) >> enter On))
                 ) |> (reply currentState))
         .| ((event :: Event Stop)
              ~> (  ((== ExitShutdown) ~? (\_ -> timeout (seconds 3) Reset))
                 .| ((const True) ~? stop)
                 ))
         .| ((event :: Event Check) ~> reply stateData)
         .| (event :: Event Reset)
              ~> (allState $ \Reset -> put initCount >> enter Off)

walkingAnFsmTree :: Process ()
walkingAnFsmTree = do
  pid <- start Off initCount switchFsm

  (sp, rp) <- newChan :: Process (SendPort Message, ReceivePort Message)

  send pid (wrapMessage (() :: ButtonPush), sp)
  msg <- receiveChan rp :: Process Message
  mSt <- unwrapMessage msg :: Process (Maybe State)
  mSt `shouldBe` equalTo (Just On)

  send pid (wrapMessage (() :: ButtonPush), sp)
  msg' <- receiveChan rp :: Process Message
  mSt' <- unwrapMessage msg' :: Process (Maybe State)
  mSt' `shouldBe` equalTo (Just Off)

  send pid (wrapMessage Check, sp)
  chk <- receiveChan rp :: Process Message
  mCk <- unwrapMessage chk :: Process (Maybe StateData)
  mCk `shouldBe` equalTo (Just $ (2 :: StateData))

  send pid ExitShutdown
  sleep $ seconds 6
  alive <- isProcessAlive pid
  liftIO $ putStrLn $ "alive == " ++ (show alive)
  alive `shouldBe` equalTo True

  send pid (wrapMessage Check, sp)
  chk2 <- receiveChan rp :: Process Message
  mCk2 <- unwrapMessage chk2 :: Process (Maybe StateData)
  mCk2 `shouldBe` equalTo (Just $ (0 :: StateData))

  send pid (wrapMessage (() :: ButtonPush), sp)
  rst' <- receiveChan rp :: Process Message
  mrst' <- unwrapMessage rst' :: Process (Maybe State)
  mrst' `shouldBe` equalTo (Just On)

  send pid ExitNormal
  sleep $ seconds 5
  alive' <- isProcessAlive pid
  liftIO $ putStrLn $ "alive' == " ++ (show alive')
  alive' `shouldBe` equalTo False

myRemoteTable :: RemoteTable
myRemoteTable =
  Control.Distributed.Process.Extras.__remoteTable $  initRemoteTable

tests :: NT.Transport  -> IO [Test]
tests transport = do
  {- verboseCheckWithResult stdArgs -}
  localNode <- newLocalNode transport myRemoteTable
  return [
        testGroup "Language/DSL"
        [
          testCase "Traversing an FSM definition"
           (runProcess localNode walkingAnFsmTree)
        ]
    ]

main :: IO ()
main = testMain $ tests

-- | Given a @builder@ function, make and run a test suite on a single transport
testMain :: (NT.Transport -> IO [Test]) -> IO ()
testMain builder = do
  Right (transport, _) <- createTransportExposeInternals
                                    "127.0.0.1" "10501" defaultTCPParameters
  testData <- builder transport
  defaultMain testData
