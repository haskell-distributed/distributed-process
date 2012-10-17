module Main 
  ( main
  -- Shush the compiler about unused definitions
  , logShow
  , forAllShrink
  , inits
  ) where

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
  , elements
  )
import Test.QuickCheck.Property (morallyDubiousIOProperty, Result(..), result)
import Test.HUnit (Assertion, assertFailure)
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Exception (Exception, throwIO)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, writeChan, readChan)
import Control.Monad (replicateM)
import Data.List (inits)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import qualified Data.ByteString as BSS (concat)

import Network.Transport
import Network.Transport.TCP 
  ( createTransportExposeInternals
  , defaultTCPParameters
  , TransportInternals(socketBetween)
  )

import Network.Transport.TCP.Mock.Socket (scheduleReadAction, sClose)

--------------------------------------------------------------------------------
-- Script infrastructure                                                      --
--------------------------------------------------------------------------------

-- | We randomly generate /scripts/ which are essentially a deep embedding of
-- the Transport API. These scripts are then executed and the results compared
-- against an abstract interpreter.
data ScriptCmd = 
    -- | Create a new endpoint
    NewEndPoint
    -- | @Connect i j@ creates a connection from endpoint @i@ to endpoint @j@,
    -- where @i@ and @j@ are indices and refer to the @i@th and @j@th endpoint
    -- created by NewEndPoint
  | Connect Int Int 
    -- | @Close i@ closes the @i@ connection created using 'Connect'. Note that
    -- closing a connection does not shift other indices; in other words, in
    -- @[Connect 0 0, Close 0, Connect 0 0, Close 0]@ the second 'Close'
    -- refers to the first (already closed) connection
  | Close Int 
    -- | @Send i bs@ sends payload @bs@ on the @i@ connection created 
  | Send Int [ByteString]
    -- | @BreakAfterReads n i j@ force-closes the socket between endpoints @i@
    -- and @j@ after @n@ reads by @i@ 
    -- 
    -- We should have @i /= j@ because the TCP transport does not use sockets
    -- for connections from an endpoint to itself
  | BreakAfterReads Int Int Int
  deriving Show

type Script = [ScriptCmd]

execScript :: (Transport, TransportInternals) -> Script -> IO (Map Int [Event]) 
execScript (transport, transportInternals) script = do
    chan <- newChan
    runScript chan script
    collectAll chan
  where
    runScript :: Chan (Maybe (Int, Event)) -> Script -> IO () 
    runScript chan = go [] []
      where
        go :: [EndPoint] -> [Connection] -> Script -> IO ()
        go _endPoints _conns [] = do
          threadDelay 10000
          writeChan chan Nothing
        go endPoints conns (NewEndPoint : cmds) = do
          endPoint <- throwIfLeft $ newEndPoint transport
          let endPointIx = length endPoints
          _tid <- forkIO $ forwardTo chan (endPointIx, endPoint)
          threadDelay 10000
          go (endPoints ++ [endPoint]) conns cmds
        go endPoints conns (Connect fr to : cmds) = do
          conn <- throwIfLeft $ connect (endPoints !! fr) (address (endPoints !! to)) ReliableOrdered defaultConnectHints
          threadDelay 10000
          go endPoints (conns ++ [conn]) cmds 
        go endPoints conns (Close connIx : cmds) = do
          close (conns !! connIx)
          threadDelay 10000
          go endPoints conns cmds
        go endPoints conns (Send connIx payload : cmds) = do
          Right () <- send (conns !! connIx) payload
          threadDelay 10000
          go endPoints conns cmds
        go endPoints conns (BreakAfterReads n i j : cmds) = do
          sock <- socketBetween transportInternals (address (endPoints !! i)) (address (endPoints !! j))
          scheduleReadAction sock n (sClose sock)  
          go endPoints conns cmds

    forwardTo :: Chan (Maybe (Int, Event)) -> (Int, EndPoint) -> IO ()
    forwardTo chan (ix, endPoint) = go
      where
        go :: IO ()
        go = do
          ev <- receive endPoint
          case ev of
            EndPointClosed -> return () 
            _              -> writeChan chan (Just (ix, ev)) >> go 

    collectAll :: Chan (Maybe (Int, Event)) -> IO (Map Int [Event]) 
    collectAll chan = go Map.empty 
      where
        go :: Map Int [Event] -> IO (Map Int [Event])
        go acc = do
          mEv <- readChan chan
          case mEv of
            Nothing       -> return $ Map.map reverse acc
            Just (ix, ev) -> go (Map.alter (insertEvent ev) ix acc)

    insertEvent :: Event -> Maybe [Event] -> Maybe [Event]
    insertEvent ev Nothing    = Just [ev]
    insertEvent ev (Just evs) = Just (ev : evs)

verify :: Script -> Map Int [Event] -> Maybe String 
verify script = go script []
  where
    go :: Script -> [(Int, ConnectionId)] -> Map Int [Event] -> Maybe String
    go [] _conns evs = 
      if concat (Map.elems evs) == [] 
         then Nothing
         else Just $ "Unexpected events: " ++ show evs
    go (NewEndPoint : cmds) conns evs =
      go cmds conns evs
    go (Connect _fr to : cmds) conns evs =
      let epEvs = evs Map.! to
      in case epEvs of
        (ConnectionOpened connId _rel _addr : epEvs') ->
          go cmds (conns ++ [(to, connId)]) (Map.insert to epEvs' evs)
        _ -> 
          Just $ "Missing (ConnectionOpened <<connId>> <<rel>> <<addr>>) event in " ++ show evs
    go (Close connIx : cmds) conns evs = 
      let (epIx, connId) = conns !! connIx 
          epEvs          = evs Map.! epIx
      in case epEvs of
        (ConnectionClosed connId' : epEvs') | connId' == connId ->
          go cmds conns (Map.insert epIx epEvs' evs)
        _ -> 
          Just $ "Missing (ConnectionClosed " ++ show connId ++ ") event in " ++ show evs
    go (Send connIx payload : cmds) conns evs = 
      let (epIx, connId) = conns !! connIx 
          epEvs          = evs Map.! epIx 
      in case epEvs of
        (Received connId' payload' : epEvs') | connId' == connId && BSS.concat payload == BSS.concat payload' ->
          go cmds conns (Map.insert epIx epEvs' evs)
        _ -> 
          Just $ "Missing (Received " ++ show connId ++ " " ++ show payload ++ ") event in " ++ show epEvs 
    go (BreakAfterReads n i j : cmds) conns evs = 
      go cmds conns evs

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
              payload <- arbitrary 
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
          -- We sometimes want big delays, but usually we want short delays
          numReads <- elements (concat (replicate 10 [0 .. 9]) ++ [10 ..99]) 
          return $ Connect i j : BreakAfterReads numReads i j : cmds
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
      testGroup "Bugs" [
        testOne "Bug1" transport script_Bug1
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
      evs <- execScript transport script 
      return $ case verify script evs of
        Nothing  -> result { ok     = Just True 
                           }
        Just err -> result { ok     = Just False
                           , reason = '\n' : err ++ "\nAll events: " ++ show evs 
                           }

testScript :: (Transport, TransportInternals) -> Script -> Assertion
testScript transport script = do
  logShow script 
  evs <- execScript transport script 
  case verify script evs of
    Just err -> assertFailure $ "Failed with script " ++ show script ++ ": " ++ err
    Nothing  -> return ()

--------------------------------------------------------------------------------
-- Auxiliary
--------------------------------------------------------------------------------

logShow :: Show a => a -> IO ()
logShow = appendFile "log" . (++ "\n") . show

throwIfLeft :: Exception a => IO (Either a b) -> IO b
throwIfLeft p = do
  mb <- p
  case mb of
    Left a  -> throwIO a
    Right b -> return b

instance Arbitrary ByteString where
  arbitrary = do
    len <- choose (0, 10)
    xs  <- replicateM len arbitrary
    return (pack xs)
