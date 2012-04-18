-- | In-memory implementation of the Transport API.
module Network.Transport.Chan (createTransport) where

import Network.Transport 
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, (!))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC (pack)

-- Global state: next available "address", mapping from addresses to channels and next available connection
type TransportState = (Int, Map ByteString (Chan Event, Int))

-- | Create a new Transport.
--
-- Only a single transport should be created per Haskell process
-- (threads can, and should, create their own endpoints though).
createTransport :: IO Transport
createTransport = do
  endpoints <- newMVar (0, Map.empty)
  return Transport { newEndPoint = chanNewEndPoint endpoints }

-- Create a new end point
chanNewEndPoint :: MVar TransportState -> IO (Either Error EndPoint)
chanNewEndPoint endpoints = do
  chan <- newChan
  addr <- modifyMVar endpoints $ \(next, state) -> do
                                   let addr = BSC.pack (show next)
                                   return ((next + 1, Map.insert addr (chan, 0) state), addr)
  return . Right $ EndPoint { receive = readChan chan  
                            , address = Address addr
                            , connect = chanConnect (Address addr) endpoints
                            , newMulticastGroup     = undefined
                            , resolveMulticastGroup = undefined
                            }
  
-- Create a new connection
chanConnect :: Address -> MVar TransportState -> Address -> Reliability -> IO (Either Error Connection)
chanConnect myAddress endpoints (Address theirAddress) _ = do 
  (chan, conn) <- modifyMVar endpoints $ \(next, state) -> do
                                           let (chan, conn) = state Map.! theirAddress
                                           return ((next, Map.insert theirAddress (chan, conn + 1) state), (chan, conn))
  writeChan chan $ ConnectionOpened conn ReliableOrdered myAddress
  return . Right $ Connection { send         = writeChan chan . Receive conn 
                              , close        = writeChan chan $ ConnectionClosed conn
                              }
