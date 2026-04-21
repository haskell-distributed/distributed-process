module Network.Transport.Tests.Multicast where

import Network.Transport
import Control.Monad (replicateM, replicateM_, forM_, when)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, putMVar, readMVar)
import Data.ByteString (ByteString)
import Data.List (elemIndex)
import Network.Transport.Tests.Auxiliary (runTests)
import Network.Transport.Tests.Expect (expectReceivedMulticast, expectRight)

-- | Node for the "No confusion" test
noConfusionNode :: Transport -- ^ Transport
                -> [MVar MulticastAddress] -- ^ my group : groups to subscribe to
                -> [MVar ()]               -- ^ I'm ready : others ready
                -> Int                     -- ^ number of pings
                -> [ByteString]            -- ^ my message : messages from subscribed groups (same order as 'groups to subscribe to')
                -> MVar ()                 -- ^ I'm done
                -> IO ()
noConfusionNode transport groups ready numPings msgs done = do
  -- Create a new endpoint
  endpoint <- expectRight "noConfusionNode: newEndPoint" =<< newEndPoint transport

  -- Create a new multicast group and broadcast its address
  myGroup <- expectRight "noConfusionNode: newMulticastGroup" =<< newMulticastGroup endpoint
  putMVar (head groups) (multicastAddress myGroup)

  -- Subscribe to the given multicast groups
  addrs <- mapM readMVar (tail groups)
  forM_ addrs $ \addr -> do
    group <- expectRight "noConfusionNode: resolveMulticastGroup" =<< resolveMulticastGroup endpoint addr
    multicastSubscribe group

  -- Indicate that we're ready and wait for everybody else to be ready
  putMVar (head ready) ()
  mapM_ readMVar (tail ready)

  -- Send messages..
  forkIO . replicateM_ numPings $ multicastSend myGroup [head msgs]

  -- ..while checking that the messages we receive are the right ones
  replicateM_ (2 * numPings) $ do
    (addr, payload) <- expectReceivedMulticast =<< receive endpoint
    case payload of
      [msg] ->
        case addr `elemIndex` addrs of
          Nothing -> error $ "Message from unexpected source: " ++ show addr
          Just ix -> when (msgs !! (ix + 1) /= msg) $
            error $ "Unexpected message from " ++ show addr
                 ++ ": expected " ++ show (msgs !! (ix + 1))
                 ++ ", got " ++ show msg
      _ ->
        error $ "expected ReceivedMulticast with a single fragment, got " ++ show (length payload) ++ " fragments"

  -- Success
  putMVar done ()

-- | Test that distinct multicast groups are not confused
testNoConfusion :: Transport -> Int -> IO ()
testNoConfusion transport numPings = do
  [group1, group2, group3] <- replicateM 3 newEmptyMVar
  [readyA, readyB, readyC] <- replicateM 3 newEmptyMVar
  [doneA, doneB, doneC]    <- replicateM 3 newEmptyMVar
  let [msgA, msgB, msgC]    = ["A says hi", "B says hi", "C says hi"]

  forkIO $ noConfusionNode transport [group1, group1, group2] [readyA, readyB, readyC] numPings [msgA, msgA, msgB] doneA
  forkIO $ noConfusionNode transport [group2, group1, group3] [readyB, readyC, readyA] numPings [msgB, msgA, msgC] doneB
  forkIO $ noConfusionNode transport [group3, group2, group3] [readyC, readyA, readyB] numPings [msgC, msgB, msgC] doneC

  mapM_ takeMVar [doneA, doneB, doneC]

-- | Test multicast
testMulticast :: Transport -> IO ()
testMulticast transport =
  runTests
    [ ("NoConfusion", testNoConfusion transport 10000) ]
