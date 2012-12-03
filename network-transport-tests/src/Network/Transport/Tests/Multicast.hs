module Network.Transport.Tests.Multicast where

import Network.Transport
import Control.Monad (replicateM, replicateM_, forM_, when)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, takeMVar, putMVar, readMVar)
import Data.ByteString (ByteString)
import Data.List (elemIndex)
import Network.Transport.Tests.Auxiliary (runTests)

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
  Right endpoint <- newEndPoint transport

  -- Create a new multicast group and broadcast its address
  Right myGroup <- newMulticastGroup endpoint
  putMVar (head groups) (multicastAddress myGroup)

  -- Subscribe to the given multicast groups
  addrs <- mapM readMVar (tail groups)
  forM_ addrs $ \addr -> do Right group <- resolveMulticastGroup endpoint addr
                            multicastSubscribe group

  -- Indicate that we're ready and wait for everybody else to be ready
  putMVar (head ready) ()
  mapM_ readMVar (tail ready)

  -- Send messages..
  forkIO . replicateM_ numPings $ multicastSend myGroup [head msgs]

  -- ..while checking that the messages we receive are the right ones
  replicateM_ (2 * numPings) $ do
    event <- receive endpoint
    case event of
      ReceivedMulticast addr [msg] ->
        let mix = addr `elemIndex` addrs in
        case mix of
          Nothing -> error "Message from unexpected source"
          Just ix -> when (msgs !! (ix + 1) /= msg) $ error "Unexpected message"
      _ ->
        error "Unexpected event"

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
