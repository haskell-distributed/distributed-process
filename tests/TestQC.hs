import Test.Framework (defaultMain, testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.QuickCheck (Gen, choose, suchThatMaybe, forAll)
import Test.QuickCheck.Property (morallyDubiousIOProperty, Result(..), result)
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Applicative ((<$>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, writeChan, readChan)
import Control.Monad (forM_, replicateM)
import Data.Either (rights)

import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)

data ScriptCmd = 
    Connect Int Int Reliability ConnectHints 
  | Close Int 

instance Show ScriptCmd where
  show (Connect fr to _ _) = "Connect " ++ show fr ++ " " ++ show to
  show (Close i) = "Close " ++ show i

type Script = [ScriptCmd]

logShow :: Show a => a -> IO ()
logShow = appendFile "log" . (++ "\n") . show

connectCloseScript :: Int -> Gen Script
connectCloseScript numEndPoints = go Map.empty 
  where
    go :: Map Int Bool -> Gen Script
    go conns = do
      next <- choose (0, 2) :: Gen Int
      case next of
        0 -> do
         fr <- choose (0, numEndPoints - 1)
         to <- choose (0, numEndPoints - 1)
         cmds <- go (Map.insert (Map.size conns) True conns) 
         return (Connect fr to ReliableOrdered defaultConnectHints : cmds)
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

execScript :: Transport -> Int -> Script -> IO (Map Int [Event]) 
execScript transport numEndPoints script = do
    endPoints <- rights <$> replicateM numEndPoints (newEndPoint transport)
    chan <- newChan
    forM_ (zip [0..] endPoints) $ forkIO . forwardTo chan 
    forkIO $ runScript endPoints [] script
    collectAll chan 0
  where
    runScript :: [EndPoint] -> [Connection] -> Script -> IO () 
    runScript endPoints = go
      where
        go :: [Connection] -> Script -> IO ()
        go _ [] = threadDelay 500000 >> mapM_ closeEndPoint endPoints 
        go conns cmd@(Connect fr to rel hints : cmds) = do
          Right conn <- connect (endPoints !! fr) (address (endPoints !! to)) rel hints
          go (conns ++ [conn]) cmds 
        go conns cmd@(Close connIx : cmds) = do
          close (conns !! connIx)
          go conns cmds

    forwardTo :: Chan (Int, Event) -> (Int, EndPoint) -> IO ()
    forwardTo chan (ix, endPoint) = go
      where
        go :: IO ()
        go = do
          ev <- receive endPoint
          writeChan chan (ix, ev)
          case ev of
            EndPointClosed -> return () 
            _              -> go 

    collectAll :: Chan (Int, Event) -> Int -> IO (Map Int [Event]) 
    collectAll chan = go (Map.fromList (zip [0 .. numEndPoints - 1] (repeat []))) 
      where
        go :: Map Int [Event] -> Int -> IO (Map Int [Event])
        go acc numDone | numDone == numEndPoints = return $ Map.map reverse acc
        go acc numDone = do
          logShow acc
          (ix, ev) <- readChan chan
          let acc'     = Map.adjust (ev :) ix acc
              numDone' = case ev of EndPointClosed -> numDone + 1
                                    _              -> numDone
          go acc' numDone'

verify :: Int -> Script -> Map Int [Event] -> Result
verify numEndPoints script evs = 
    case go script [] evs of
      Nothing  -> result { ok     = Just True 
                         }
      Just err -> result { ok     = Just False
                         , reason = err 
                         }
  where
    go :: Script -> [(Int, ConnectionId)] -> Map Int [Event] -> Maybe String
    go [] conns evs = 
      let closed = Map.fromList (zip [0 .. numEndPoints - 1] (repeat [EndPointClosed])) in
      if evs == closed then Nothing 
                       else Just $ "Expected " ++ show closed ++ "; got " ++ show evs
    go (Connect fr to rel hints : cmds) conns evs =
      case evs Map.! to of
        (ConnectionOpened connId rel' addr : epEvs) | rel' == rel ->
          go cmds (conns ++ [(to, connId)]) (Map.insert to epEvs evs)
        _ -> Just $ "Missing ConnectionOpened event in " ++ show evs
    go (Close connIx : cmds) conns evs = 
      let (epIx, connId) = conns !! connIx in
      case evs Map.! epIx of
        (ConnectionClosed connId' : epEvs) | connId' == connId ->
          go cmds conns (Map.insert epIx epEvs evs)
        _ -> Just $ "Missing ConnectionClosed event in " ++ show evs

prop_connect_close transport = forAll (connectCloseScript 2) $ \script -> 
  morallyDubiousIOProperty $ do 
    logShow script
    evs <- execScript transport 2 script 
    return (verify 2 script evs)

tests transport = [
    testGroup "Unidirectional" [
      testProperty "ConnectClose" (prop_connect_close transport)
    ]
  ]

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)
