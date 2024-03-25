

import Control.Concurrent (forkIO, threadDelay)
import qualified Control.Concurrent.MVar as MVar
import Control.Distributed.Process (NodeId, Process, liftIO)
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Monad (forM_)
import qualified Data.List as List
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

main :: IO ()
main = defaultMain 
     $ testGroup "Test suite" 
     [ testDiscoverNodes
     ]

testDiscoverNodes :: TestTree
testDiscoverNodes = testCase "discover nodes" $ do

  -- Initialize slave nodes
  forM_ ["10000", "10001", "10002", "10003"] $ \port -> do
    backend <- initializeBackend "127.0.0.1" port initRemoteTable
    _ <- forkIO $ startSlave backend
    threadDelay 100000
  
  -- initialize master node
  discoveredNodesSlot <- MVar.newEmptyMVar
  backend <- initializeBackend "127.0.0.1" "10004" initRemoteTable
  startMaster backend $ \nds -> do
    terminateAllSlaves backend
    liftIO $ MVar.putMVar discoveredNodesSlot nds

  discoveredNodes <- (List.sort . List.nub) <$> MVar.readMVar discoveredNodesSlot
  assertEqual "Discovered nodes" 
              [ "nid://127.0.0.1:10000:0"
              , "nid://127.0.0.1:10001:0"
              , "nid://127.0.0.1:10002:0"
              , "nid://127.0.0.1:10003:0"
              ] 
              (map show discoveredNodes)


