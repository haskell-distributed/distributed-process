module Main where

import Network.Transport
import Network.Transport.TCP

import Control.Monad
import Network.Socket (HostName, ServiceName)
import System.Environment

import qualified Data.ByteString.Lazy.Char8 as BS

import Debug.Trace

type ChanId = Int

-- | This example demonstrates how a master can be connected to slaves using
-- the transport layer. After compiling, the following will initialize a new
-- master that waits for two clients to connect on the local machine:
--
--     ./DemoTCP 127.0.0.1 8080 sourceAddrFile 2
--
-- Following this, two slaves should be created that will connect to the master:
--
--     ./DemoTCP 127.0.0.1 8081 sourceAddrFile
--     ./DemoTCP 127.0.0.1 8082 sourceAddrFile
--
-- Once the connection is established, the slaves will provide the master
-- with their SourceAddr. The master then decodes this, and sends a message
-- back. After processing this message, the slaves respond to the master,
-- which then outputs some data.
main :: IO ()
main = do
  args <- getArgs
  case args of
    -- Master:
    -- The master only provides the host, service, and slaves to expect.
    [host, service, sourceAddrFilePath, number] -> do
      let numSlaves = read number
      transport <- mkTransport $ TCPConfig defaultHints host service
      (clientSourceEnds, masterTargetEnd) <- demoMaster transport sourceAddrFilePath numSlaves
      zipWithM_
        (\clientSourceEnd clientId -> send clientSourceEnd [BS.pack . show $ clientId])
        clientSourceEnds [0 .. numSlaves-1]
      replicateM_ numSlaves $ do
        [clientMessage] <- receive masterTargetEnd
        print clientMessage

    -- Slave:
    -- Each slave provides its own host and service, as well as details of
    -- the master it wishes to connect to.
    [host, service, sourceAddrFilePath] -> do
      transport <- mkTransport $ TCPConfig defaultHints host service
      (masterSourceEnd, slaveTargetEnd) <- demoSlave transport sourceAddrFilePath
      [clientId] <- receive slaveTargetEnd
      putStrLn $ "slave: received clientId: " ++ show clientId
      let message = "Connected to slave: " ++ BS.unpack clientId

      send masterSourceEnd [BS.pack message]
      putStrLn "slave: sent message to master"

    _ -> error "Unexpected arguments"

demoMaster :: Transport                  -- ^ Transport
           -> FilePath                   -- ^ File to write SourceAddr
           -> Int                        -- ^ Number of slaves to expect
           -> IO ([SourceEnd], TargetEnd)
demoMaster transport sourceAddrFilePath numSlaves = do
  -- Establish an initial transport
  (sourceAddr, targetEnd) <- newConnection transport

  -- Write a file containing the sourceAddr
  putStrLn $ "master: writing sourceAddr file:" ++ (show . serialize $ sourceAddr)
  BS.writeFile sourceAddrFilePath $ serialize sourceAddr

  -- Deserialize each of the sourceEnds received by the slaves
  sourceEnds <- replicateM numSlaves $ do
    [bytes] <- receive targetEnd
    putStrLn "master: received connection."
    case deserialize transport bytes of
      Nothing       -> fail "Garbage message from slave!"
      Just sourceAddr -> connect sourceAddr
  return (sourceEnds, targetEnd)

demoSlave :: Transport                -- ^ Transport
          -> FilePath                 -- ^ File to read SourceAddr
          -> IO (SourceEnd, TargetEnd)
demoSlave transport masterSourceAddrFilePath = do
  -- Create a new connection on the transport
  (sourceAddr, targetEnd) <- newConnection transport

  -- Establish connection with the master
  bytes <- BS.readFile masterSourceAddrFilePath
  case deserialize transport bytes of
    Just masterSourceAddr -> do
      putStrLn $ "slave: connecting to sourceAddr: " ++ (show . serialize $ masterSourceAddr)
      masterSourceEnd <- connect masterSourceAddr

      -- Source the serialized address of this slave
      send masterSourceEnd [serialize sourceAddr]
      putStrLn "slave: sent sourceAddr"
      return (masterSourceEnd, targetEnd)

    Nothing -> error "slave: Unable to deserialize master SourceAddr!"

