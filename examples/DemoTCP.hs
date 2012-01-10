module Main where

import Network.Transport
import Network.Transport.TCP

import Control.Monad
import Network.Socket (HostName, ServiceName)
import System.Environment

import qualified Data.ByteString.Char8 as BS

import Debug.Trace

type ChanId = Int

-- | This example demonstrates how a master can be connected to slaves using
-- the transport layer.
main :: IO ()
main = do
  args <- getArgs
  case args of
    -- Master:
    -- The master only provides the host, service, and slaves to expect.
    [host, service, sendAddrFilePath, number] -> do
      let numSlaves = read number
      transport <- mkTransport $ TCPConfig defaultHints host service
      (clientSendEnds, masterReceiveEnd) <- demoMaster transport sendAddrFilePath numSlaves
      zipWithM_
        (\clientSendEnd clientId -> send clientSendEnd [BS.pack . show $ clientId])
        clientSendEnds [0 .. numSlaves-1]
      replicateM_ numSlaves $ do
        [clientMessage] <- receive masterReceiveEnd
        print clientMessage

    -- Slave:
    -- Each slave provides its own host and service, as well as details of
    -- the master it wishes to connect to.
    [host, service, sendAddrFilePath] -> do
      transport <- mkTransport $ TCPConfig defaultHints host service
      (masterSendEnd, slaveReceiveEnd) <- demoSlave transport sendAddrFilePath
      [clientId] <- receive slaveReceiveEnd
      putStrLn $ "slave: received clientId: " ++ show clientId
      let message = "Connected to slave: " ++ BS.unpack clientId

      send masterSendEnd [BS.pack message]
      putStrLn "slave: sent message to master"

    _ -> error "Unexpected arguments"

demoMaster :: Transport                  -- ^ Transport
           -> FilePath                   -- ^ File to write SendAddr
           -> Int                        -- ^ Number of slaves to expect
           -> IO ([SendEnd], ReceiveEnd)
demoMaster transport sendAddrFilePath numSlaves = do
  -- Establish an initial transport
  (sendAddr, receiveEnd) <- newConnection transport

  -- Write a file containing the sendAddr
  putStrLn $ "master: writing sendAddr file:" ++ (show . serialize $ sendAddr)
  BS.writeFile sendAddrFilePath $ serialize sendAddr

  -- Deserialize each of the sendEnds received by the slaves
  sendEnds <- replicateM numSlaves $ do
    [bytes] <- receive receiveEnd
    putStrLn "master: received connection."
    case deserialize transport bytes of
      Nothing       -> fail "Garbage message from slave!"
      Just sendAddr -> connect sendAddr
  return (sendEnds, receiveEnd)

demoSlave :: Transport                -- ^ Transport
          -> FilePath                 -- ^ File to read SendAddr
          -> IO (SendEnd, ReceiveEnd)
demoSlave transport masterSendAddrFilePath = do
  -- Create a new connection on the transport
  (sendAddr, receiveEnd) <- newConnection transport

  -- Establish connection with the master
  bytes <- BS.readFile masterSendAddrFilePath
  case deserialize transport bytes of
    Just masterSendAddr -> do
      putStrLn $ "slave: connecting to sendAddr: " ++ (show . serialize $ masterSendAddr)
      masterSendEnd <- connect masterSendAddr

      -- Send the serialized address of this slave
      send masterSendEnd [serialize sendAddr]
      putStrLn "slave: sent sendAddr"
      return (masterSendEnd, receiveEnd)

    Nothing -> error "slave: Unable to deserialize master SendAddr!"

