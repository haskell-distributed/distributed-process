{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}

module Main where

import Control.Distributed.Process hiding (call, send, sendChan)
import Control.Distributed.Process.UnsafePrimitives (send, sendChan)
import Control.Distributed.Process.Node
import Control.Distributed.Process.Extras
 ( ExitReason(..)
 , isProcessAlive
 )
import qualified Control.Distributed.Process.Extras (__remoteTable)
import Control.Distributed.Process.Extras.Time hiding (timeout)
import Control.Distributed.Process.Extras.Timer
import Control.Distributed.Process.FSM hiding (State, liftIO)
import Control.Distributed.Process.FSM.Client (call, callTimeout)
import Control.Distributed.Process.SysTest.Utils
import Control.Monad (replicateM_, forM_)
import Control.Rematch (equalTo)

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, drop)
#else
import Prelude hiding (drop, (*>))
#endif

import Test.Framework as TF (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit

import Network.Transport.TCP
import qualified Network.Transport as NT

-- import Control.Distributed.Process.Serializable (Serializable)
-- import Control.Monad (void)
import Data.Binary (Binary)
import Data.Maybe (fromJust)
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

waitForDown :: MonitorRef -> Process DiedReason
waitForDown ref =
  receiveWait [ matchIf (\(ProcessMonitorNotification ref' _ _) -> ref == ref')
                        (\(ProcessMonitorNotification _ _ dr) -> return dr) ]

switchFsm :: Step State StateData
switchFsm = startState
         ^. ((event :: Event ButtonPush)
              ~> (  (On  ~@ (set (+1) >> enter Off)) -- on => off => on is possible with |> here...
                 .| (Off ~@ (set (+1) >> enter On))
                 ) |> (reply currentState))
         .| ((event :: Event Stop)
              ~> (  ((== ExitNormal) ~? (\_ -> timeout (seconds 3) Reset))
                    {- let's verify that we can't override a normal shutdown sequence... -}
                 .| ((== ExitShutdown) ~? (\_ -> timeout (seconds 3) Reset))
                 .| ((const True) ~? stop)
                 ))
         .| ((event :: Event Check) ~> reply stateData)
         .| (event :: Event Reset)
              ~> (allState $ \Reset -> put initCount >> enter Off)

switchFsmAlt :: Step State StateData
switchFsmAlt =
  begin startState $
    pick (await (event :: Event ButtonPush) ((pick (atState On  (set (+1) >> enter Off))
                                                   (atState Off (set (+1) >> enter On))) `join` (reply currentState)))
         (pick (await (event :: Event Stop) (pick (matching (== ExitNormal) (\_ -> timeout (seconds 3) Reset))
                                                  (matching (const True) stop)))
               (pick (await (event :: Event Check) (reply stateData))
                     (await (event :: Event Reset) (always $ \Reset -> put initCount >> enter Off))))

blockingFsm :: SendPort () -> Step State ()
blockingFsm sp = initState Off ()
            ^.  ((event :: Event ())
                *> (allState $ \() -> (lift $ sleep (seconds 10) >> sendChan sp ()) >> resume))
             .| ((event :: Event Stop)
                ~> (  ((== ExitNormal)   ~? (\_ -> resume) )
                      {- let's verify that we can't override
                         a normal shutdown sequence... -}
                   .| ((== ExitShutdown) ~? const resume)
                   ))

deepFSM :: SendPort () -> SendPort () -> Step State ()
deepFSM on off = initState Off ()
       ^. ((event :: Event State) ~> (allState $ \s -> enter s))
       .| ( (whenStateIs Off)
            |> (  ((event :: Event ())
                    ~> (allState $ \s -> (lift $ sendChan off s) >> resume))
               .| (((event :: Event String) ~> (always $ \(_ :: String) -> resume))
                    |> (reply (currentInput >>= return . fromJust :: FSM State () String)))
               )
          )
       .| ( (On ~@ resume) -- equivalent to `whenStateIs On`
            |> ((event :: Event ())
                ~> (allState $ \s -> (lift $ sendChan on s) >> resume))
          )

genFSM :: SendPort () -> Step State ()
genFSM sp = initState Off ()
       ^. ( (whenStateIs Off)
            |> ((event :: Event ()) ~> (always $ \() -> postpone))
          )
       .| ( (((pevent 100) :: Event State) ~> (always $ \state -> enter state))
         .| ((event :: Event ()) ~> (always $ \() -> (lift $ sendChan sp ()) >> resume))
          )
       .| ( (event :: Event String)
             ~> ( (Off ~@ putBack)
               .| (On  ~@ (nextEvent ()))
                )
          )

republicationOfEvents :: Process ()
republicationOfEvents = do
  (sp, rp) <- newChan

  pid <- start Off () $ genFSM sp

  replicateM_ 15 $ send pid ()

  Nothing <- receiveChanTimeout (asTimeout $ seconds 5) rp

  send pid On

  replicateM_ 15 $ receiveChan rp

  send pid "hello"  -- triggers `nextEvent ()`

  res <- receiveChanTimeout (asTimeout $ seconds 5) rp :: Process (Maybe ())
  res `shouldBe` equalTo (Just ())

  send pid Off

  forM_ ([1..50] :: [Int]) $ \i -> send pid i
  send pid "yo"
  send pid On

  res' <- receiveChanTimeout (asTimeout $ seconds 20) rp :: Process (Maybe ())
  res' `shouldBe` equalTo (Just ())

  kill pid "thankyou byebye"

verifyOuterStateHandler :: Process ()
verifyOuterStateHandler = do
  (spOn, rpOn) <- newChan
  (spOff, rpOff) <- newChan

  pid <- start Off () $ deepFSM spOn spOff

  send pid On
  send pid ()
  Nothing <- receiveChanTimeout (asTimeout $ seconds 3) rpOff
  () <- receiveChan rpOn

  resp <- callTimeout pid "hello there" (seconds 3):: Process (Maybe String)
  resp `shouldBe` equalTo (Nothing :: Maybe String)

  send pid Off
  send pid ()
  Nothing <- receiveChanTimeout (asTimeout $ seconds 3) rpOn
  () <- receiveChan rpOff

  res <- call pid "hello" :: Process String
  res `shouldBe` equalTo "hello"

  kill pid "bye bye"

verifyMailboxHandling :: Process ()
verifyMailboxHandling = do
  (sp, rp) <- newChan :: Process (SendPort (), ReceivePort ())
  pid <- start Off () (blockingFsm sp)

  send pid ()
  exit pid ExitNormal

  sleep $ seconds 5
  alive <- isProcessAlive pid
  alive `shouldBe` equalTo True

  -- we should resume after the ExitNormal handler runs, and get back into the ()
  -- handler due to safeWait (*>) which adds a `safe` filter check for the given type
  () <- receiveChan rp

  exit pid ExitShutdown
  monitor pid >>= waitForDown
  alive' <- isProcessAlive pid
  alive' `shouldBe` equalTo False

verifyStopBehaviour :: Process ()
verifyStopBehaviour = do
  pid <- start Off initCount switchFsm
  alive <- isProcessAlive pid
  alive `shouldBe` equalTo True

  exit pid $ ExitOther "foobar"
  monitor pid >>= waitForDown
  alive' <- isProcessAlive pid
  alive' `shouldBe` equalTo False

notSoQuirkyDefinitions :: Process ()
notSoQuirkyDefinitions = do
  start Off initCount switchFsmAlt >>= walkingAnFsmTree

quirkyOperators :: Process ()
quirkyOperators = do
  start Off initCount switchFsm >>= walkingAnFsmTree

walkingAnFsmTree :: ProcessId -> Process ()
walkingAnFsmTree pid = do
  mSt <- call pid (() :: ButtonPush) :: Process State
  mSt `shouldBe` equalTo On

  mSt' <- call pid (() :: ButtonPush) :: Process State
  mSt' `shouldBe` equalTo Off

  mCk <- call pid Check :: Process StateData
  mCk `shouldBe` equalTo (2 :: StateData)

  -- verify that the process implementation turns exit signals into handlers...
  exit pid ExitNormal
  sleep $ seconds 6
  alive <- isProcessAlive pid
  alive `shouldBe` equalTo True

  mCk2 <- call pid Check :: Process StateData
  mCk2 `shouldBe` equalTo (0 :: StateData)

  mrst' <- call pid (() :: ButtonPush) :: Process State
  mrst' `shouldBe` equalTo On

  exit pid ExitShutdown
  monitor pid >>= waitForDown
  alive' <- isProcessAlive pid
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
          testCase "Traversing an FSM definition (operators)"
           (runProcess localNode quirkyOperators)
        , testCase "Traversing an FSM definition (functions)"
           (runProcess localNode notSoQuirkyDefinitions)
        , testCase "Traversing an FSM definition (exit handling)"
           (runProcess localNode verifyStopBehaviour)
        , testCase "Traversing an FSM definition (mailbox handling)"
           (runProcess localNode verifyMailboxHandling)
        , testCase "Traversing an FSM definition (nested definitions)"
           (runProcess localNode verifyOuterStateHandler)
        , testCase "Traversing an FSM definition (event re-publication)"
           (runProcess localNode republicationOfEvents)
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
