import Test.Framework (defaultMain, testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.QuickCheck (Gen, choose, suchThatMaybe, forAll)
import Test.QuickCheck.Property (morallyDubiousIOProperty)
import Data.Map (Map)
import qualified Data.Map as Map

import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)

data ScriptCmd = 
    Connect Int Int Reliability ConnectHints 
  | Close Int 

instance Show ScriptCmd where
  show (Connect fr to _ _) = "Connect " ++ show fr ++ " " ++ show to
  show (Close i) = "Close " ++ show i

type Script = [ScriptCmd]

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
          mConn <- suchThatMaybe (choose (0, Map.size conns - 1)) (conns Map.!)
          case mConn of 
            Nothing -> go conns
            Just conn -> do
              cmds <- go (Map.insert conn False conns)
              return (Close conn : cmds) 
        _ ->
          return []

execScript :: [EndPoint] -> Script -> IO [Event]
execScript endPoints = go [] [] 
  where
   go :: [Event] -> [(Connection, Int)] -> Script -> IO [Event]
   go acc _ [] = return (reverse acc)
   go acc conns (Connect fr to rel hints : cmds) = do
     Right conn <- connect (endPoints !! fr) (address (endPoints !! to)) rel hints
     ev <- receive (endPoints !! to)
     go (ev : acc) (conns ++ [(conn, to)]) cmds 
   go acc conns (Close connIdx : cmds) = do
     let (conn, connDst) = conns !! connIdx
     close conn 
     ev <- receive (endPoints !! connDst)
     go (ev : acc) conns cmds

prop_connect_close transport = forAll (connectCloseScript 2) $ \script -> 
  morallyDubiousIOProperty $ do 
    Right endPointA <- newEndPoint transport
    Right endPointB <- newEndPoint transport
    evs <- execScript [endPointA, endPointB] script 
    return (evs == [])

tests transport = [
    testGroup "Unidirectional" [
      testProperty "ConnectClose" (prop_connect_close transport)
    ]
  ]

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  defaultMain (tests transport)
