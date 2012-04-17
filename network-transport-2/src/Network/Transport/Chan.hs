-- | Implementation of the Transport which creates a single Chan for every endpoint.
module Network.Transport.Chan (createTransport) where

import Network.Transport 
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar)
import Data.Map (Map)
import qualified Data.Map as Map (empty, insert, (!), member)

-- Global state: mapping from endpoint identities to the number of the next available connection
type TransportState = Map Identity Int

-- | Create a new Transport
createTransport :: IO Transport
createTransport = do
  endpoints <- newMVar Map.empty
  return Transport { newEndPoint = chanNewEndPoint endpoints }

-- Create a new end point
chanNewEndPoint :: MVar TransportState -> Identity -> IO (Either Error EndPoint)
chanNewEndPoint endpoints identity = do
  state <- takeMVar endpoints
  if identity `Map.member` state 
    then do
      putMVar endpoints state
      return . Left $ Error undefined ("Identifier " ++ show identity ++ " already used")
    else do
      putMVar endpoints (Map.insert identity 0 state) 
      chan <- newChan
      return . Right $ EndPoint { receive = readChan chan  
                                , address = Address identity 
                                , connect = chanConnect chan endpoints
                                , multicastNewGroup    = undefined
                                , multicastConnect     = undefined
                                , multicastSubscribe   = undefined
                                , multicastUnsubscribe = undefined
                                }
  
-- Create a new connection
chanConnect :: Chan Event -> MVar TransportState -> Address -> Reliability -> IO (Either Error Connection)
chanConnect chan endpoints (Address identity) _ = do 
  state <- takeMVar endpoints
  let conn = state Map.! identity 
  putMVar endpoints (Map.insert identity (conn + 1) state)
  writeChan chan $ ConnectionOpened conn ReliableOrdered
  return . Right $ Connection { connId = conn 
                              , send   = writeChan chan . Receive conn 
                              , close  = writeChan chan $ ConnectionClosed conn
                              }
