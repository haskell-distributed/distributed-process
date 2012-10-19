module Main 
  ( main
  -- Shush the compiler about unused definitions
  , log
  , logShow
  , forAllShrink
  , inits
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
import Control.Arrow (second)
import Control.Applicative ((<$>))
import Control.Exception (Exception, throwIO, try)
import Control.Concurrent (forkIO, threadDelay, ThreadId, killThread)
import Control.Monad (replicateM, forever, guard)
import Control.Monad.State.Lazy (StateT, execStateT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Typeable (Typeable)
import Data.Maybe (isJust)
import Data.List (inits)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import Data.Accessor (Accessor, accessor, (^.))
import Data.Accessor.Monad.Trans.State (get, modify)
import qualified Data.Accessor.Container as DAC (mapDefault)
import qualified Data.ByteString as BSS (concat)
import qualified Text.PrettyPrint as PP
import Data.Unique (Unique, newUnique, hashUnique)
import Data.Concurrent.Queue.MichaelScott (newQ, pushL, tryPopR)

import Network.Transport
import Network.Transport.TCP 
  ( createTransportExposeInternals
  , defaultTCPParameters
  , TransportInternals
  )

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

data ExpEvent =
    ExpConnectionOpened (Variable ConnectionId)
  | ExpConnectionClosed (Variable ConnectionId)
  | ExpReceived (Variable ConnectionId) [ByteString]
  deriving Show

type TargetAddress = EndPointAddress

data RunState = RunState {
    _endPoints         :: [EndPoint]
  , _connections       :: [(TargetAddress, Connection, Variable ConnectionId)]
  , _expectedEvents    :: Map EndPointAddress [ExpEvent]
  , _forwardingThreads :: [ThreadId]
  }

initialRunState :: RunState 
initialRunState = RunState {
    _endPoints      = []
  , _connections    = []
  , _expectedEvents = Map.empty
  , _forwardingThreads = []
  }

verify :: (Transport, TransportInternals) -> Script -> IO (Either String ())
verify (transport, _transportInternals) script = do
  allEvents <- newQ

  let runScript :: Script -> StateT RunState IO ()
      runScript = mapM_ runCmd 

      runCmd :: ScriptCmd -> StateT RunState IO () 
      runCmd NewEndPoint = do
        mEndPoint <- liftIO $ newEndPoint transport
        case mEndPoint of
          Right endPoint -> do
            modify endPoints (snoc endPoint)
            tid <- liftIO $ forkIO (forward endPoint) 
            modify forwardingThreads (tid :)
          Left err ->
            liftIO $ throwIO err
      runCmd (Connect i j) = do
        endPointA <- get (endPointAtIx i)
        endPointB <- address <$> get (endPointAtIx j)
        mConn <- liftIO $ connect endPointA endPointB ReliableOrdered defaultConnectHints
        case mConn of
          Right conn -> do
            connId <- Variable <$> liftIO newUnique 
            modify connections (snoc (endPointB, conn, connId))
            modify (expectedEventsAt endPointB) (snoc (ExpConnectionOpened connId))
          Left err ->
            liftIO $ throwIO err
      runCmd (Close i) = do
        (target, conn, connId) <- get (connectionAt i)
        liftIO $ close conn
        modify (expectedEventsAt target) (snoc (ExpConnectionClosed connId))
      runCmd (Send i payload) = do
        (target, conn, connId) <- get (connectionAt i)
        mResult <- liftIO $ send conn payload
        case mResult of
          Right () -> return ()
          Left err -> liftIO $ throwIO err
        modify (expectedEventsAt target) (snoc (ExpReceived connId payload))
      runCmd (BreakAfterReads _n _i _j) =
        expectedFailure "BreakAfterReads not implemented"
 
      forward :: EndPoint -> IO ()
      forward endPoint = forever $ do
        ev <- receive endPoint
        pushL allEvents (address endPoint, ev)

      collectEvents :: RunState -> IO (Map EndPointAddress [Event]) 
      collectEvents st = do
          threadDelay 10000
          mapM_ killThread (st ^. forwardingThreads)
          evs <- go []
          return (groupByKey evs)
        where
          go acc = do
            mEv <- tryPopR allEvents
            case mEv of
              Just ev -> go (ev : acc)
              Nothing -> return acc 
        
  st <- execStateT (runScript script) initialRunState 
  actualEvents <- collectEvents st
 
  let eventsMatch = and . map (uncurry match) $ 
        zip (Map.elems (st ^. expectedEvents))
        (Map.elems actualEvents)

  return $ if eventsMatch 
             then Right () 
             else Left ("Could not match " ++ show (st ^. expectedEvents)
                                ++ " and " ++ show actualEvents)

--------------------------------------------------------------------------------
-- Match expected and actual events                                           --
--------------------------------------------------------------------------------

-- | Match a list of expected events to a list of actual events, taking into
-- account that events may be reordered
match :: [ExpEvent] -> [Event] -> Bool
match expected actual = or (map (isJust . flip unify actual) (reorder expected))

-- | Match a list of expected events to a list of actual events, without doing
-- reordering
unify :: [ExpEvent] -> [Event] -> Maybe () 
unify [] [] = return () 
unify (ExpConnectionOpened connId : expected) (ConnectionOpened connId' _ _ : actual) = do 
  subst <- unifyConnectionId connId connId' 
  unify (apply subst expected) actual
unify (ExpConnectionClosed connId : expected) (ConnectionClosed connId' : actual) = do
  subst <- unifyConnectionId connId connId'
  unify (apply subst expected) actual
unify (ExpReceived connId payload : expected) (Received connId' payload' : actual) = do
  guard (BSS.concat payload == BSS.concat payload')
  subst <- unifyConnectionId connId connId'
  unify (apply subst expected) actual
unify _ _ = fail "Cannot unify" 

type Substitution a = Map Unique a

-- | Match two connection IDs
unifyConnectionId :: Variable ConnectionId -> ConnectionId -> Maybe (Substitution ConnectionId)
unifyConnectionId (Variable x)    connId = Just $ Map.singleton x connId
unifyConnectionId (Value connId') connId | connId == connId' = Just Map.empty
                                         | otherwise         = Nothing

-- | Apply a substitution
apply :: Substitution ConnectionId -> [ExpEvent] -> [ExpEvent]
apply subst = map applyEvent 
  where
    applyEvent :: ExpEvent -> ExpEvent
    applyEvent (ExpConnectionOpened connId) = ExpConnectionOpened (applyVar connId)
    applyEvent (ExpConnectionClosed connId) = ExpConnectionClosed (applyVar connId)
    applyEvent (ExpReceived connId payload) = ExpReceived (applyVar connId) payload

    applyVar :: Variable ConnectionId -> Variable ConnectionId
    applyVar (Value connId) = Value connId
    applyVar (Variable x)   = case Map.lookup x subst of 
                                Just connId -> Value connId
                                Nothing     -> Variable x

-- | Return all possible reorderings of a list of expected events
--
-- Events from different connections can be reordered, but events from the 
-- same connection cannot.
reorder :: [ExpEvent] -> [[ExpEvent]]
reorder = go
  where
    go :: [ExpEvent] -> [[ExpEvent]]
    go []         = [[]]
    go (ev : evs) = concat [insert ev evs' | evs' <- reorder evs]

    insert :: ExpEvent -> [ExpEvent] -> [[ExpEvent]]
    insert ev [] = [[ev]]
    insert ev (ev' : evs') 
      | connectionId ev == connectionId ev' = [ev : ev' : evs']
      | otherwise = (ev : ev' : evs') : [ev' : evs'' | evs'' <- insert ev evs']

    connectionId :: ExpEvent -> Variable ConnectionId
    connectionId (ExpConnectionOpened connId) = connId
    connectionId (ExpConnectionClosed connId) = connId
    connectionId (ExpReceived connId _)       = connId

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
          numReads <- chooseFrom' (NormalD { mean = 5, stdDev = 10 }) (0, 100)
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
script_BreakConnect :: Script
script_BreakConnect = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , BreakAfterReads 1 1 0
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
      testGroup "Specific scripts" [
        testOne "Bug1"         transport script_Bug1
      , testOne "BreakSend"    transport script_BreakSend
      , testOne "BreakConnect" transport script_BreakConnect
      ]
    , testGroup "One endpoint, with delays"    (basicTests transport 1 id) 
    , testGroup "Two endpoints, with delays"   (basicTests transport 2 id) 
    , testGroup "Three endpoints, with delays" (basicTests transport 3 id)
    , testGroup "Four endpoints, with delay, single error" (basicTests transport 4 (withErrors 1))
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

connections :: Accessor RunState [(TargetAddress, Connection, Variable ConnectionId)]
connections = accessor _connections (\cs st -> st { _connections = cs })

connectionAt :: ConnectionIx -> Accessor RunState (TargetAddress, Connection, Variable ConnectionId)
connectionAt i = connections >>> listAccessor i

expectedEvents :: Accessor RunState (Map EndPointAddress [ExpEvent])
expectedEvents = accessor _expectedEvents (\es st -> st { _expectedEvents = es })

expectedEventsAt :: EndPointAddress -> Accessor RunState [ExpEvent]
expectedEventsAt addr = expectedEvents >>> DAC.mapDefault [] addr

forwardingThreads :: Accessor RunState [ThreadId]
forwardingThreads = accessor _forwardingThreads (\ts st -> st { _forwardingThreads = ts })

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
    len <- chooseFrom' (NormalD { mean = 5, stdDev = 10 }) (0, 100) 
    xs  <- replicateM len arbitrary
    return (pack xs)

listAccessor :: Int -> Accessor [a] a
listAccessor i = accessor (!! i) (error "listAccessor.set not defined") 

snoc :: a -> [a] -> [a]
snoc x xs = xs ++ [x]

groupByKey :: Ord a => [(a, b)] -> Map a [b]
groupByKey = Map.fromListWith (++) . map (second return) 

--------------------------------------------------------------------------------
-- Expected failures (can't find explicit support for this in test-framework) --
--------------------------------------------------------------------------------

data ExpectedFailure = ExpectedFailure String deriving (Typeable, Show)

instance Exception ExpectedFailure

expectedFailure :: MonadIO m => String -> m ()
expectedFailure = liftIO . throwIO . ExpectedFailure
