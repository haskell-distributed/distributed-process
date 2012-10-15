module Main (main, logShow) where

import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.Framework.Providers.HUnit (testCase)
import Test.QuickCheck (Gen, choose, suchThatMaybe, forAll, forAllShrink, Property)
import Test.QuickCheck.Property (morallyDubiousIOProperty, Result(..), result)
import Test.HUnit (Assertion, assertFailure)
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Exception (Exception, throwIO)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, writeChan, readChan)
import Data.List (inits)

import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)

data ScriptCmd = 
    NewEndPoint
  | Connect Int Int 
  | Close Int 
  deriving Show

type Script = [ScriptCmd]

logShow :: Show a => a -> IO ()
logShow = appendFile "log" . (++ "\n") . show

throwIfLeft :: Exception a => IO (Either a b) -> IO b
throwIfLeft p = do
  mb <- p
  case mb of
    Left a  -> throwIO a
    Right b -> return b

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

execScript :: Transport -> Script -> IO (Map Int [Event]) 
execScript transport script = do
    chan <- newChan
    runScript chan script
    collectAll chan
  where
    runScript :: Chan (Maybe (Int, Event)) -> Script -> IO () 
    runScript chan = go [] []
      where
        go :: [EndPoint] -> [Connection] -> Script -> IO ()
        go _endPoints _conns [] = do
          threadDelay 100000
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
      case evs Map.! to of
        (ConnectionOpened connId _rel _addr : epEvs) ->
          go cmds (conns ++ [(to, connId)]) (Map.insert to epEvs evs)
        _ -> Just $ "Missing (ConnectionOpened <<connId>> <<rel>> <<addr>>) event in " ++ show evs
    go (Close connIx : cmds) conns evs = 
      let (epIx, connId) = conns !! connIx in
      case evs Map.! epIx of
        (ConnectionClosed connId' : epEvs) | connId' == connId ->
          go cmds conns (Map.insert epIx epEvs evs)
        _ -> Just $ "Missing (ConnectionClosed " ++ show connId ++ ") event in " ++ show evs

testScript1 :: Script
testScript1 = [
    NewEndPoint
  , NewEndPoint
  , Connect 0 1
  , Close 0
  , Connect 1 0
  , Close 1
  , Connect 1 0
  ]

genericProp :: Transport -> Gen Script -> Property
genericProp transport scriptGen = 
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

testOneScript :: Transport -> Script -> Assertion
testOneScript transport script = do
  logShow script 
  evs <- execScript transport script 
  case verify script evs of
    Just err -> assertFailure $ "Failed with script " ++ show script ++ ": " ++ err
    Nothing  -> return ()

tests :: Transport -> [Test]
tests transport = [
    testGroup "Unidirectional" [
    --  testProperty "NewEndPoint"  (genericProp transport (script_NewEndPoint 2))
    --, testProperty "Connect"      (genericProp transport (script_Connect 2))
       testCase "testScript1" (testOneScript transport testScript1)
    -- testProperty "ConnectClose" (genericProp transport (script_ConnectClose 2))
    ]
  ]

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)
