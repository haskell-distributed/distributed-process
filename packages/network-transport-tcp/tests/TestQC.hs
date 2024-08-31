-- Test the TCP transport using QuickCheck generated scripts
--
-- TODO: This is not quite working yet. The main problem, I think, is the
-- allocation of "bundle ID"s to connections. The problem is exposed by the
-- aptly-named regression test script_Foo (to be renamed once I figure out what
-- bug that test is actually exposing :)
module Main
  ( main
  -- Shush the compiler about unused definitions
  , log
  , logShow
  , forAllShrink
  , inits
  , expectedFailure
  ) where

import Prelude hiding (log)
import Test.Framework (Test, TestName, defaultMain, testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.Framework.Providers.HUnit (testCase)
import Test.QuickCheck
  ( Gen
  , choose
  , suchThatMaybe
  , forAll
  , forAllShrink
  , Property
  , Arbitrary(arbitrary)
  )
import Test.QuickCheck.Property (morallyDubiousIOProperty, Result(..), result)
import Test.HUnit (Assertion, assertFailure)
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Category ((>>>))
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, try)
import Control.Concurrent (forkIO, threadDelay, ThreadId, killThread)
import Control.Monad (MonadPlus(..), replicateM, forever, guard)
import Control.Monad.State (StateT, execStateT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Typeable (Typeable)
import Data.Maybe (isJust)
import Data.List (inits)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Data.Accessor (Accessor, accessor, (^.))
import Data.Accessor.Monad.Trans.State (get, set, modify)
import qualified Data.Accessor.Container as DAC (set, mapDefault)
import qualified Data.ByteString as BSS (concat)
import qualified Text.PrettyPrint as PP
import Data.Unique (Unique, newUnique, hashUnique)
import Data.Concurrent.Queue.MichaelScott (newQ, pushL, tryPopR)
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Stack (currentCallStack, renderStack)

import Network.Transport
import Network.Transport.TCP
  ( createTransportExposeInternals
  , defaultTCPParameters
  , TransportInternals(socketBetween)
  )
import Network.Transport.TCP.Mock.Socket (Socket, scheduleReadAction, sClose)

--------------------------------------------------------------------------------
-- Script infrastructure                                                      --
--------------------------------------------------------------------------------

type EndPointIx       = Int
type SourceEndPointIx = Int
type TargetEndPointIx = Int
type ConnectionIx     = Int

-- | We randomly generate /scripts/ which are essentially a deep embedding of
-- the Transport API. These scripts are then executed and the results compared
-- against an abstract interpreter.
data ScriptCmd =
    -- | Create a new endpoint
    NewEndPoint
    -- | @Connect i j@ creates a connection from endpoint @i@ to endpoint @j@,
    -- where @i@ and @j@ are indices and refer to the @i@th and @j@th endpoint
    -- created by NewEndPoint
  | Connect SourceEndPointIx TargetEndPointIx
    -- | @Close i@ closes the @i@ connection created using 'Connect'. Note that
    -- closing a connection does not shift other indices; in other words, in
    -- @[Connect 0 0, Close 0, Connect 0 0, Close 0]@ the second 'Close'
    -- refers to the first (already closed) connection
  | Close ConnectionIx
    -- | @Send i bs@ sends payload @bs@ on the @i@ connection created
  | Send ConnectionIx [ByteString]
    -- | @BreakAfterReads n i j@ force-closes the socket between endpoints @i@
    -- and @j@ after @n@ reads by @i@
    --
    -- We should have @i /= j@ because the TCP transport does not use sockets
    -- for connections from an endpoint to itself
  | BreakAfterReads Int SourceEndPointIx TargetEndPointIx
  deriving Show

type Script = [ScriptCmd]

--------------------------------------------------------------------------------
-- Execute and verify scripts                                                 --
--------------------------------------------------------------------------------

data Variable a = Value a | Variable Unique
  deriving Eq

instance Show a => Show (Variable a) where
  show (Value x) = show x
  show (Variable u) = "<<" ++ show (hashUnique u) ++ ">>"

-- | In the implementation "bundles" are purely a conceptual idea, but in the
-- verifier we need to concretize this notion
type BundleId = Int

data ConnectionInfo = ConnectionInfo {
    source           :: EndPointAddress
  , target           :: EndPointAddress
  , connectionId     :: Variable ConnectionId
  , connectionBundle :: BundleId
  }
  deriving Show

data ExpEvent =
    ExpConnectionOpened ConnectionInfo
  | ExpConnectionClosed ConnectionInfo
  | ExpReceived ConnectionInfo [ByteString]
  | ExpConnectionLost BundleId EndPointAddress
  deriving Show

data RunState = RunState {
    _endPoints      :: [EndPoint]
  , _connections    :: [(Connection, ConnectionInfo)]
  , _expectedEvents :: Map EndPointAddress [ExpEvent]
    -- | For each endpoint we create we create a thread that forwards the events
    -- of that endpoint to a central channel. We collect the thread IDs so that
    -- we can kill these thread when we are done.
  , _forwardingThreads :: [ThreadId]
    -- | When a connection from A to be may break, we add both (A, B, n)
    -- and (B, A, n) to _mayBreak. Then once we detect that from A to B
    -- has in fact broken we move (A, B, n), *and/or* (B, A, n), from _mayBreak
    -- to _broken. Note that we can detect that a connection has been broken
    -- in one direction even if we haven't yet detected that the connection
    -- has broken in the other direction.
    --
    -- | Invariant: not mayBreak && broken
  , _mayBreak :: Set (EndPointAddress, EndPointAddress, BundleId)
  , _broken   :: Set (EndPointAddress, EndPointAddress, BundleId)
    -- | Current bundle ID between two endpoints
    --
    -- Invariant: For all keys (A, B), A <= B
  , _currentBundle :: Map (EndPointAddress, EndPointAddress) BundleId
  }

initialRunState :: RunState
initialRunState = RunState {
    _endPoints         = []
  , _connections       = []
  , _expectedEvents    = Map.empty
  , _forwardingThreads = []
  , _mayBreak          = Set.empty
  , _broken            = Set.empty
  , _currentBundle     = Map.empty
  }

verify :: (Transport, TransportInternals) -> Script -> IO (Either String ())
verify (transport, transportInternals) script = do
  allEvents <- newQ

  let runScript :: Script -> StateT RunState IO ()
      runScript = mapM_ runCmd

      runCmd :: ScriptCmd -> StateT RunState IO ()
      runCmd NewEndPoint = do
        mEndPoint <- liftIO $ newEndPoint transport
        case mEndPoint of
          Right endPoint -> do
            tid <- liftIO $ forkIO (forward endPoint)
            append endPoints endPoint
            append forwardingThreads tid
            set (expectedEventsAt (address endPoint)) []
          Left err ->
            liftIO $ throwIO err
      runCmd (Connect i j) = do
        endPointA <- get (endPointAtIx i)
        endPointB <- address <$> get (endPointAtIx j)
        mConn <- liftIO $ connect endPointA endPointB ReliableOrdered defaultConnectHints
        let bundleId     = currentBundle (address endPointA) endPointB
            connBroken   = broken        (address endPointA) endPointB
            connMayBreak = mayBreak      (address endPointA) endPointB
        case mConn of
          Right conn -> do
            bundleBroken <- get bundleId >>= get . connBroken
            currentBundleId <- if bundleBroken
              then modify bundleId (+ 1) >> get bundleId
              else get bundleId
            connId <- Variable <$> liftIO newUnique
            let connInfo = ConnectionInfo {
                               source           = address endPointA
                             , target           = endPointB
                             , connectionId     = connId
                             , connectionBundle = currentBundleId
                             }
            append connections (conn, connInfo)
            append (expectedEventsAt endPointB) (ExpConnectionOpened connInfo)
          Left err -> do
            currentBundleId <- get bundleId
            expectingBreak  <- get $ connMayBreak currentBundleId
            if expectingBreak
              then do
                set (connMayBreak currentBundleId) False
                set (connBroken   currentBundleId) True
              else
                liftIO $ throwIO err
      runCmd (Close i) = do
        (conn, connInfo) <- get (connectionAt i)
        liftIO $ close conn
        append (expectedEventsAt (target connInfo)) (ExpConnectionClosed connInfo)
      runCmd (Send i payload) = do
        (conn, connInfo) <- get (connectionAt i)
        mResult <- liftIO $ send conn payload
        let connMayBreak = mayBreak (source connInfo) (target connInfo) (connectionBundle connInfo)
            connBroken   = broken   (source connInfo) (target connInfo) (connectionBundle connInfo)
        case mResult of
          Right () -> return ()
          Left err -> do
            expectingBreak <- get connMayBreak
            isBroken       <- get connBroken
            if expectingBreak || isBroken
              then do
                set connMayBreak False
                set connBroken   True
              else
                liftIO $ throwIO err
        append (expectedEventsAt (target connInfo)) (ExpReceived connInfo payload)
      -- TODO: This will only work if a connection between 'i' and 'j' has
      -- already been established. We would need to modify the mock network
      -- layer to support breaking "future" connections
      runCmd (BreakAfterReads n i j) = do
        endPointA <- address <$> get (endPointAtIx i)
        endPointB <- address <$> get (endPointAtIx j)
        liftIO $ do
          sock <- socketBetween transportInternals endPointA endPointB
          scheduleReadAction sock n $ breakSocket sock
        currentBundleId <- get (currentBundle endPointA endPointB)
        set (mayBreak endPointA endPointB currentBundleId) True
        set (mayBreak endPointB endPointA currentBundleId) True
        append (expectedEventsAt endPointA) (ExpConnectionLost currentBundleId endPointB)
        append (expectedEventsAt endPointB) (ExpConnectionLost currentBundleId endPointA)

      forward :: EndPoint -> IO ()
      forward endPoint = forever $ do
        ev <- receive endPoint
        pushL allEvents (address endPoint, ev)

      collectEvents :: RunState -> IO (Map EndPointAddress [Event])
      collectEvents st = do
          threadDelay 10000
          mapM_ killThread (st ^. forwardingThreads)
          evs <- go []
          return $ groupByKey (map address (st ^. endPoints)) evs
        where
          go acc = do
            mEv <- tryPopR allEvents
            case mEv of
              Just ev -> go (ev : acc)
              Nothing -> return (reverse acc)

  st <- execStateT (runScript script) initialRunState
  actualEvents <- collectEvents st

  let eventsMatch = all (uncurry match) $
        zip (Map.elems (st ^. expectedEvents))
        (Map.elems actualEvents)

  return $ if eventsMatch
             then Right ()
             else Left ("Could not match " ++ show (st ^. expectedEvents)
                                ++ " and " ++ show actualEvents)

breakSocket :: Socket -> IO ()
breakSocket sock = do
  currentCallStack >>= putStrLn . renderStack
  sClose sock

--------------------------------------------------------------------------------
-- Match expected and actual events                                           --
--------------------------------------------------------------------------------

-- | Match a list of expected events to a list of actual events, taking into
-- account that events may be reordered
match :: [ExpEvent] -> [Event] -> Bool
match expected actual = any (`canUnify` actual) (possibleTraces expected)

possibleTraces :: [ExpEvent] -> [[ExpEvent]]
possibleTraces = go
  where
    go [] = [[]]
    go (ev@(ExpConnectionLost _ _) : evs) =
      [ trace | evs' <- possibleTraces evs, trace <- insertConnectionLost ev evs' ]
    go (ev : evs) =
      [ trace | evs' <- possibleTraces evs, trace <- insertEvent ev evs' ]

    -- We don't know when exactly the error will occur (indeed, it may never
    -- happen at all), but it must occur before any future connection lost
    -- event to the same destination.
    -- If it occurs now, then all other events on this bundle will not happen.
    insertConnectionLost :: ExpEvent -> [ExpEvent] -> [[ExpEvent]]
    insertConnectionLost ev [] = [[ev], []]
    insertConnectionLost ev@(ExpConnectionLost bid addr) (ev' : evs) =
      (ev : removeBundle bid (ev' : evs)) :
      case ev' of
        ExpConnectionLost _ addr' | addr == addr' -> []
        _ -> [ev' : evs' | evs' <- insertConnectionLost ev evs]
    insertConnectionLost _ _ = error "The impossible happened"

    -- All other events can be arbitrarily reordered /across/ connections, but
    -- never /within/ connections
    insertEvent :: ExpEvent -> [ExpEvent] -> [[ExpEvent]]
    insertEvent ev [] = [[ev]]
    insertEvent ev (ev' : evs) =
      (ev : ev' : evs) :
      if eventConnId ev == eventConnId ev'
        then []
        else [ev' : evs' | evs' <- insertEvent ev evs]

    removeBundle :: BundleId -> [ExpEvent] -> [ExpEvent]
    removeBundle bid = filter ((/= bid) . eventBundleId)

    eventBundleId :: ExpEvent -> BundleId
    eventBundleId (ExpConnectionOpened connInfo) = connectionBundle connInfo
    eventBundleId (ExpConnectionClosed connInfo) = connectionBundle connInfo
    eventBundleId (ExpReceived connInfo _)       = connectionBundle connInfo
    eventBundleId (ExpConnectionLost bid _)      = bid

    eventConnId :: ExpEvent -> Maybe (Variable ConnectionId)
    eventConnId (ExpConnectionOpened connInfo) = Just $ connectionId connInfo
    eventConnId (ExpConnectionClosed connInfo) = Just $ connectionId connInfo
    eventConnId (ExpReceived connInfo _)       = Just $ connectionId connInfo
    eventConnId (ExpConnectionLost _ _)        = Nothing

--------------------------------------------------------------------------------
-- Unification                                                                --
--------------------------------------------------------------------------------

type Substitution = Map Unique ConnectionId

newtype Unifier a = Unifier {
    runUnifier :: Substitution -> Maybe (a, Substitution)
  }

instance Monad Unifier where
  return x = Unifier $ \subst -> Just (x, subst)
  x >>= f  = Unifier $ \subst -> case runUnifier x subst of
                                   Nothing -> Nothing
                                   Just (a, subst') -> runUnifier (f a) subst'
  fail _str = mzero

instance MonadPlus Unifier where
  mzero = Unifier $ const Nothing
  f `mplus` g = Unifier $ \subst -> case runUnifier f subst of
                                      Nothing          -> runUnifier g subst
                                      Just (a, subst') -> Just (a, subst')

class Unify a b where
  unify :: a -> b -> Unifier ()

canUnify :: Unify a b => a -> b -> Bool
canUnify a b = isJust $ runUnifier (unify a b) Map.empty

instance Unify Unique ConnectionId where
  unify x cid = Unifier $ \subst ->
    case Map.lookup x subst of
      Just cid' -> if cid == cid' then Just ((), subst)
                                  else Nothing
      Nothing   -> Just ((), Map.insert x cid subst)

instance Unify (Variable ConnectionId) ConnectionId where
  unify (Variable x)    connId = unify x connId
  unify (Value connId') connId = guard $ connId' == connId

instance Unify ExpEvent Event where
  unify (ExpConnectionOpened connInfo) (ConnectionOpened connId _ _) =
    unify (connectionId connInfo) connId
  unify (ExpConnectionClosed connInfo) (ConnectionClosed connId) =
    unify (connectionId connInfo) connId
  unify (ExpReceived connInfo payload) (Received connId payload') = do
    guard $ BSS.concat payload == BSS.concat payload'
    unify (connectionId connInfo) connId
  unify (ExpConnectionLost _ addr) (ErrorEvent (TransportError (EventConnectionLost addr') _)) =
    guard $ addr == addr'
  unify _ _ = fail "Cannot unify"

instance Unify a b => Unify [a] [b] where
  unify []     []     = return ()
  unify (x:xs) (y:ys) = unify x y >> unify xs ys
  unify _      _      = fail "Cannot unify"

--------------------------------------------------------------------------------
-- Script generators                                                          --
--------------------------------------------------------------------------------

script_NewEndPoint :: Int -> Gen Script
script_NewEndPoint numEndPoints = return (replicate numEndPoints NewEndPoint)

script_Connect :: Int -> Gen Script
script_Connect numEndPoints = do
    script <- go
    return (replicate numEndPoints NewEndPoint ++ script)
  where
    go :: Gen Script
    go = do
      next <- choose (0, 1) :: Gen Int
      case next of
        0 -> do
         fr <- choose (0, numEndPoints - 1)
         to <- choose (0, numEndPoints - 1)
         cmds <- go
         return (Connect fr to : cmds)
        _ ->
          return []

script_ConnectClose :: Int -> Gen Script
script_ConnectClose numEndPoints = do
    script <- go Map.empty
    return (replicate numEndPoints NewEndPoint ++ script)
  where
    go :: Map Int Bool -> Gen Script
    go conns = do
      next <- choose (0, 2) :: Gen Int
      case next of
        0 -> do
         fr <- choose (0, numEndPoints - 1)
         to <- choose (0, numEndPoints - 1)
         cmds <- go (Map.insert (Map.size conns) True conns)
         return (Connect fr to : cmds)
        1 -> do
          mConn <- choose (0, Map.size conns - 1) `suchThatMaybe` isOpen conns
          case mConn of
            Nothing -> go conns
            Just conn -> do
              cmds <- go (Map.insert conn False conns)
              return (Close conn : cmds)
        _ ->
          return []

    isOpen :: Map Int Bool -> Int -> Bool
    isOpen conns connIx = connIx `Map.member` conns && conns Map.! connIx

script_ConnectSendClose :: Int -> Gen Script
script_ConnectSendClose numEndPoints = do
    script <- go Map.empty
    return (replicate numEndPoints NewEndPoint ++ script)
  where
    go :: Map Int Bool -> Gen Script
    go conns = do
      next <- choose (0, 3) :: Gen Int
      case next of
        0 -> do
         fr <- choose (0, numEndPoints - 1)
         to <- choose (0, numEndPoints - 1)
         cmds <- go (Map.insert (Map.size conns) True conns)
         return (Connect fr to : cmds)
        1 -> do
          mConn <- choose (0, Map.size conns - 1) `suchThatMaybe` isOpen conns
          case mConn of
            Nothing -> go conns
            Just conn -> do
              numSegments <- choose (0, 2)
              payload <- replicateM numSegments arbitrary
              cmds <- go conns
              return (Send conn payload : cmds)
        2 -> do
          mConn <- choose (0, Map.size conns - 1) `suchThatMaybe` isOpen conns
          case mConn of
            Nothing -> go conns
            Just conn -> do
              cmds <- go (Map.insert conn False conns)
              return (Close conn : cmds)
        _ ->
          return []

    isOpen :: Map Int Bool -> Int -> Bool
    isOpen conns connIx = connIx `Map.member` conns && conns Map.! connIx

withErrors :: Int -> Gen Script -> Gen Script
withErrors numErrors gen = gen >>= insertError numErrors
  where
    insertError :: Int -> Script -> Gen Script
    insertError _ [] = return []
    insertError n (Connect i j : cmds) | i /= j = do
      insert <- arbitrary
      if insert && n > 0
        then do
          numReads <- chooseFrom' NormalD { mean = 5, stdDev = 10 } (0, 100)
          swap <- arbitrary
          if swap
            then return $ Connect i j : BreakAfterReads numReads j i : cmds
            else return $ Connect i j : BreakAfterReads numReads i j : cmds
        else do
          cmds' <- insertError (n - 1) cmds
          return $ Connect i j : cmds'
    insertError n (cmd : cmds) = do
      cmds' <- insertError n cmds
      return $ cmd : cmds'

--------------------------------------------------------------------------------
-- Individual scripts to test specific bugs                                   --
--------------------------------------------------------------------------------

-- | Bug #1
--
-- When process A wants to close the heavyweight connection to process B it
-- sends a CloseSocket request together with the ID of the last connection from
-- B. When B receives the CloseSocket request it can compare this ID to the last
-- connection it created; if they don't match, B knows that there are some
-- messages still on the way from B to A (in particular, a CreatedConnection
-- message) which will cancel the CloseSocket request from A. Hence, it will
-- know to ignore the CloseSocket request from A.
--
-- The bug was that we recorded the last _created_ outgoing connection on the
-- local endpoint, but the last _received_ incoming connection on the state of
-- the heavyweight connection. So, in the script below, the following happened:
--
-- A connects to B, records "last connection ID is 1024"
-- A closes the lightweight connection, sends [CloseConnection 1024]
-- A closes the heivyweight connection, sends [CloseSocket 0]
--
--   (the 0 here indicates that it had not yet received any connections from B)
--
-- B receives the [CloseSocket 0], compares it to the recorded outgoing ID (0),
-- confirms that they are equal, and confirms the CloseSocket request.
--
-- B connects to A, records "last connection ID is 1024"
-- B closes the lightweight connection, sends [CloseConnection 1024]
-- B closes the heavyweight connection, sends [CloseSocket 0]
--
--   (the 0 here indicates that it has not yet received any connections from A,
--   ON THIS HEAVYWEIGHT connection)
--
-- A receives the [CloseSocket 0] request, compares it to the last recorded
-- outgoing ID (1024), sees that they are not equal, and concludes that this
-- must mean that there is still a CreatedConnection message on the way from A
-- to B.
--
-- This of course is not the case, so B will wait forever for A to confirm
-- the CloseSocket request, and deadlock arises. (This deadlock doesn't become
-- obvious though until the next attempt from B to connect to A.)
--
-- The solution is of course that both the recorded outgoing and recorded
-- incoming connection ID must be per heavyweight connection.
script_Bug1 :: Script
script_Bug1 = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , Close 0
  , Connect 1 0
  , Close 1
  , Connect 1 0
  ]

-- | Test ordering of sends
script_MultipleSends :: Script
script_MultipleSends = [
    NewEndPoint
  , Connect 0 0
  , Send 0 ["A"]
  , Send 0 ["B"]
  , Send 0 ["C"]
  , Send 0 ["D"]
  , Send 0 ["E"]
  ]

-- | Simulate broken network connection during send
script_BreakSend :: Script
script_BreakSend = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , BreakAfterReads 1 1 0
  , Send 0 ["ping"]
  ]

-- | Simulate broken network connection during connect
script_BreakConnect1 :: Script
script_BreakConnect1 = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , BreakAfterReads 1 1 0
  , Connect 0 1
  ]

-- | Simulate broken network connection during connect
script_BreakConnect2 :: Script
script_BreakConnect2 = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , BreakAfterReads 1 0 1
  , Connect 0 1
  ]

-- | Simulate broken send, then reconnect
script_BreakSendReconnect :: Script
script_BreakSendReconnect = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , BreakAfterReads 1 1 0
  , Send 0 ["ping1"]
  , Connect 0 1
  , Send 1 ["ping2"]
  ]

script_Foo :: Script
script_Foo = [
    NewEndPoint
  , NewEndPoint
  , Connect 1 0
  , BreakAfterReads 2 0 1
  , Send 0 ["pingpong"]
  , Connect 0 1
  ]

--------------------------------------------------------------------------------
-- Main application driver                                                    --
--------------------------------------------------------------------------------

basicTests :: (Transport, TransportInternals) -> Int -> (Gen Script -> Gen Script) -> [Test]
basicTests transport numEndPoints trans = [
    testGen "NewEndPoint"      transport (trans (script_NewEndPoint numEndPoints))
  , testGen "Connect"          transport (trans (script_Connect numEndPoints))
  , testGen "ConnectClose"     transport (trans (script_ConnectClose numEndPoints))
  , testGen "ConnectSendClose" transport (trans (script_ConnectSendClose numEndPoints))
  ]

tests :: (Transport, TransportInternals) -> [Test]
tests transport = [
      testGroup "Regression tests" [
          testOne "Bug1" transport script_Bug1
        ]
    , testGroup "Specific scripts" [
          testOne "BreakMultipleSends" transport script_MultipleSends
        , testOne "BreakSend"          transport script_BreakSend
        , testOne "BreakConnect1"      transport script_BreakConnect1
        , testOne "BreakConnect2"      transport script_BreakConnect2
        , testOne "BreakSendReconnect" transport script_BreakSendReconnect
        , testOne "Foo"                transport script_Foo
        ]
    , testGroup "Without errors" [
          testGroup "One endpoint, with delays"    (basicTests transport 1 id)
        , testGroup "Two endpoints, with delays"   (basicTests transport 2 id)
        , testGroup "Three endpoints, with delays" (basicTests transport 3 id)
        ]
    , testGroup "Single error" [
          testGroup "Two endpoints, with delays"   (basicTests transport 2 (withErrors 1))
        , testGroup "Three endpoints, with delays" (basicTests transport 3 (withErrors 1))
        ]
    ]
  where

testOne :: TestName -> (Transport, TransportInternals) -> Script -> Test
testOne label transport script = testCase label (testScript transport script)

testGen :: TestName -> (Transport, TransportInternals) -> Gen Script -> Test
testGen label transport script = testProperty label (testScriptGen transport script)

main :: IO ()
main = do
  Right transport <- createTransportExposeInternals "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)

--------------------------------------------------------------------------------
-- Test infrastructure                                                        --
--------------------------------------------------------------------------------

testScriptGen :: (Transport, TransportInternals) -> Gen Script -> Property
testScriptGen transport scriptGen =
  forAll scriptGen $ \script ->
    morallyDubiousIOProperty $ do
      logShow script
      mErr <- try $ verify transport script
      return $ case mErr of
        Left (ExpectedFailure str) ->
          result { ok     = Nothing
                 , reason = str
                 }
        Right (Left err) ->
          result { ok     = Just False
                 , reason = '\n' : err ++ "\n"
                 }
        Right (Right ()) ->
          result { ok = Just True }

testScript :: (Transport, TransportInternals) -> Script -> Assertion
testScript transport script = do
  logShow script
  mErr <- try $ verify transport script
  case mErr of
    Left (ExpectedFailure _str) ->
      return ()
    Right (Left err) ->
       assertFailure $ "Failed with script " ++ show script ++ ": " ++ err ++ "\n"
    Right (Right ()) ->
      return ()

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

endPoints :: Accessor RunState [EndPoint]
endPoints = accessor _endPoints (\es st -> st { _endPoints = es })

endPointAtIx :: EndPointIx -> Accessor RunState EndPoint
endPointAtIx i = endPoints >>> listAccessor i

connections :: Accessor RunState [(Connection, ConnectionInfo)]
connections = accessor _connections (\cs st -> st { _connections = cs })

connectionAt :: ConnectionIx -> Accessor RunState (Connection, ConnectionInfo)
connectionAt i = connections >>> listAccessor i

expectedEvents :: Accessor RunState (Map EndPointAddress [ExpEvent])
expectedEvents = accessor _expectedEvents (\es st -> st { _expectedEvents = es })

expectedEventsAt :: EndPointAddress -> Accessor RunState [ExpEvent]
expectedEventsAt addr = expectedEvents >>> DAC.mapDefault [] addr

forwardingThreads :: Accessor RunState [ThreadId]
forwardingThreads = accessor _forwardingThreads (\ts st -> st { _forwardingThreads = ts })

mayBreak :: EndPointAddress -> EndPointAddress -> BundleId -> Accessor RunState Bool
mayBreak a b bid = aux >>> DAC.set (a, b, bid)
  where
    aux = accessor _mayBreak (\bs st -> st { _mayBreak = bs })

broken :: EndPointAddress -> EndPointAddress -> BundleId -> Accessor RunState Bool
broken a b bid = aux >>> DAC.set (a, b, bid)
  where
    aux = accessor _broken (\bs st -> st { _broken = bs })

currentBundle :: EndPointAddress -> EndPointAddress -> Accessor RunState BundleId
currentBundle i j = aux >>> if i < j then DAC.mapDefault 0 (i, j)
                                     else DAC.mapDefault 0 (j, i)
  where
    aux :: Accessor RunState (Map (EndPointAddress, EndPointAddress) BundleId)
    aux = accessor _currentBundle (\mp st -> st { _currentBundle = mp })

--------------------------------------------------------------------------------
-- Pretty-printing                                                            --
--------------------------------------------------------------------------------

verticalList :: Show a => [a] -> PP.Doc
verticalList = PP.brackets . PP.vcat . map (PP.text . show)

instance Show Script where
  show = ("\n" ++) . show . verticalList

instance Show [Event] where
  show = ("\n" ++) . show . verticalList

instance Show [ExpEvent] where
  show = ("\n" ++) . show . verticalList

instance Show (Map EndPointAddress [ExpEvent]) where
  show = ("\n" ++) . show . PP.brackets . PP.vcat
       . map (\(addr, evs) -> PP.hcat . PP.punctuate PP.comma $ [PP.text (show addr), verticalList evs])
       . Map.toList

instance Show (Map EndPointAddress [Event]) where
  show = ("\n" ++) . show . PP.brackets . PP.vcat
       . map (\(addr, evs) -> PP.hcat . PP.punctuate PP.comma $ [PP.text (show addr), verticalList evs])
       . Map.toList

--------------------------------------------------------------------------------
-- Draw random values from probability distributions                          --
--------------------------------------------------------------------------------

data NormalD = NormalD { mean :: Double , stdDev :: Double }

class Distribution d where
  probabilityOf :: d -> Double -> Double

instance Distribution NormalD where
  probabilityOf d x = a * exp (-0.5 * b * b)
    where
      a = 1 / (stdDev d * sqrt (2 * pi))
      b = (x - mean d) / stdDev d

-- | Choose from a distribution
chooseFrom :: Distribution d => d -> (Double, Double) -> Gen Double
chooseFrom d (lo, hi) = findCandidate
  where
    findCandidate :: Gen Double
    findCandidate = do
      candidate <- choose (lo, hi)
      uniformSample <- choose (0, 1)
      if uniformSample < probabilityOf d candidate
        then return candidate
        else findCandidate

chooseFrom' :: Distribution d => d -> (Int, Int) -> Gen Int
chooseFrom' d (lo, hi) =
  round <$> chooseFrom d (fromIntegral lo, fromIntegral hi)

--------------------------------------------------------------------------------
-- Auxiliary
--------------------------------------------------------------------------------

log :: String -> IO ()
log = appendFile "log" . (++ "\n")

logShow :: Show a => a -> IO ()
logShow = log . show

instance Arbitrary ByteString where
  arbitrary = do
    len <- chooseFrom' NormalD { mean = 5, stdDev = 10 } (0, 100)
    xs  <- replicateM len arbitrary
    return (pack xs)

listAccessor :: Int -> Accessor [a] a
listAccessor i = accessor (!! i) (error "listAccessor.set not defined")

append :: Monad m => Accessor st [a] -> a -> StateT st m ()
append acc x = modify acc (snoc x)

snoc :: a -> [a] -> [a]
snoc x xs = xs ++ [x]

groupByKey :: Ord a => [a] -> [(a, b)] -> Map a [b]
groupByKey keys = go (Map.fromList [(key, []) | key <- keys])
  where
    go acc [] = Map.map reverse acc
    go acc ((key, val) : rest) = go (Map.adjust (val :) key acc) rest

--------------------------------------------------------------------------------
-- Expected failures (can't find explicit support for this in test-framework) --
--------------------------------------------------------------------------------

data ExpectedFailure = ExpectedFailure String deriving (Typeable, Show)

instance Exception ExpectedFailure

expectedFailure :: MonadIO m => String -> m ()
expectedFailure = liftIO . throwIO . ExpectedFailure
