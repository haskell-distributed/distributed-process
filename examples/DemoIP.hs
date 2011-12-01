module Main where

import Network.Transport
import Network.Transport.IP

import System.Environment
import Control.Monad
import qualified Data.ByteString.Char8 as BS


-- TODO:
-- * wikify duncan's email
-- * add current design to wiki
-- * link to CCI
-- * explain how to address peter's points
-- * package architecture:
--   * application layer
--   * cloud haskell layer
--   * transport layer

main :: IO ()
main = do
  [mode, numberStr, addressStr, portStr] <- getArgs

  let number  = read numberStr
  let address = Address addressStr
  let port    = read portStr

  transport <- initTransport (Config undefined)

  case mode of
    "master" -> do
      (clients, masterReceiveEnd) <- demoMaster number transport address port
      zipWithM_ (\clientSendEnd clientId -> send clientSendEnd [BS.pack . show $ clientId])
        clients [0 .. number-1]
      replicateM_ number $ do
        [clientId] <- receive masterReceiveEnd
        print clientId
    "slave" -> do
      (masterSendEnd, slaveReceiveEnd) <- demoSlave transport address port
      [clientId] <- receive slaveReceiveEnd
      let message = "Connected to slave: " ++ BS.unpack clientId
      send masterSendEnd [BS.pack message]

demoMaster :: Int -> Transport -> Address -> Port -> IO ([SendEnd], ReceiveEnd)
demoMaster numSlaves transport address port = do
  receiveEnd <- newReceiveEnd address port
  sendEnds <- replicateM numSlaves $ do
    [bytes] <- receive receiveEnd
    case deserialize transport bytes of
      Nothing       -> fail "Garbage message from slave"
      Just sendAddr -> connect sendAddr
  return (sendEnds, receiveEnd)

demoSlave :: Transport -> Address -> Port -> IO (SendEnd, ReceiveEnd)
demoSlave transport address port = do
  (selfSendAddr, selfReceiveEnd) <- newConnection transport
  sendEnd <- connect (newSendAddr address port)
  send sendEnd [serialize selfSendAddr]
  return (sendEnd, selfReceiveEnd)

