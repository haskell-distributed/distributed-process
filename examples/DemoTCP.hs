module Main where

import Network.Transport
import Network.Transport.TCP

import System.Environment
import Control.Monad
import qualified Data.ByteString.Char8 as BS

type ChanId = Int

-- | This example demonstrates how a master can be connected to slaves using
-- the transport layer.
main :: IO ()
main = do
  [mode, numberStr, host, service, chanId] <- getArgs
  case mode of
    "master" -> do
      let number  = read numberStr
      transport <- mkTransport $ TCPConfig defaultHints host service

      (clients, masterReceiveEnd) <- demoMaster number transport host service
      zipWithM_
        (\clientSendEnd clientId -> send clientSendEnd [BS.pack . show $ clientId])
        clients [0 .. number-1]
      replicateM_ number $ do
        [clientMessage] <- receive masterReceiveEnd
        print clientMessage

    "slave" -> do
      (masterSendEnd, slaveReceiveEnd) <- demoSlave transport host service
      [clientId] <- receive slaveReceiveEnd
      let message = "Connected to slave: " ++ BS.unpack clientId
      send masterSendEnd [BS.pack message]

demoMaster :: Int                        -- ^ Number of slaves
           -> Transport                  -- ^ Transport
           -> HostName                   -- ^ HostName of the master node
           -> ServiceName                -- ^ ServiceName of the master node
           -> IO ([SendEnd], ReceiveEnd)
demoMaster numSlaves transport host service = do
  trans <- mkTransport defaultHints host service
  (sendAddr, receiveEnd) <- connect trans
  putStrLn $ "Master sendAddr:" ++ show . serialize $ sendAddr

  sendEnds <- replicateM numSlaves $ do
    [bytes] <- receive receiveEnd
    case deserialize transport bytes of
      Nothing       -> fail "Garbage message from slave"
      Just sendAddr -> connect sendAddr
  return (sendEnds, receiveEnd)

demoSlave :: Transport                -- ^ Transport
          -> HostName                 -- ^ The master HostName
          -> ServiceName              -- ^ The master ServiceName
          -> ChanId                   -- ^ The master ChanId
          -> IO (SendEnd, ReceiveEnd)
demoSlave transport host service chanId = do
  sendAddr <- mkSendAddr host service chanId
  (selfSendAddr, selfReceiveEnd) <- newConnection transport
  sendEnd <- connect (newSendAddr host service)
  send sendEnd [serialize selfSendAddr]
  return (sendEnd, selfReceiveEnd)

