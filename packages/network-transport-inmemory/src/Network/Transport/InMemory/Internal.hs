{-# LANGUAGE RecursiveDo #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}
-- |
-- Module: Network.Transport.InMemory.Internal
--
-- Internal part of the implementation. This module is for internal use
-- or advanced debuging. There are no guarantees about stability of this
-- module.
module Network.Transport.InMemory.Internal
  ( createTransportExposeInternals
    -- * Internal structures
  , TransportInternals(..)
  , TransportState(..)
  , ValidTransportState(..)
  , LocalEndPoint(..)
  , LocalEndPointState(..)
  , ValidLocalEndPointState(..)
  , LocalConnection(..)
  , LocalConnectionState(..)
    -- * Low level functionality
  , apiNewEndPoint
  , apiCloseEndPoint
  , apiBreakConnection
  , apiConnect
  , apiSend
  , apiClose
  ) where

import Network.Transport
import Network.Transport.Internal ( mapIOException )
import Control.Category ((>>>))
import Control.Concurrent.STM
import Control.Exception (handle, throw)
import Data.Map (Map)
import Data.Maybe (fromJust)
import Data.Monoid
import Data.Foldable
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC (pack)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:))
import qualified Data.Accessor.Container as DAC (mapMaybe)
import Data.Typeable (Typeable)
import Prelude hiding (foldr)

data TransportState
  = TransportValid {-# UNPACK #-} !ValidTransportState
  | TransportClosed

data ValidTransportState = ValidTransportState
  { _localEndPoints :: !(Map EndPointAddress LocalEndPoint)
  , _nextLocalEndPointId :: !Int
  }

data LocalEndPoint = LocalEndPoint
  { localEndPointAddress :: !EndPointAddress
  , localEndPointChannel :: !(TChan Event)
  , localEndPointState   :: !(TVar LocalEndPointState)
  }

data LocalEndPointState
  = LocalEndPointValid {-# UNPACK #-} !ValidLocalEndPointState
  | LocalEndPointClosed

data ValidLocalEndPointState = ValidLocalEndPointState
  { _nextConnectionId :: !ConnectionId
  , _connections :: !(Map (EndPointAddress,ConnectionId) LocalConnection)
  , _multigroups :: Map MulticastAddress (TVar (Set EndPointAddress))
  }

data LocalConnection = LocalConnection
  { localConnectionId :: !ConnectionId
  , localConnectionLocalAddress :: !EndPointAddress
  , localConnectionRemoteAddress :: !EndPointAddress
  , localConnectionState :: !(TVar LocalConnectionState)
  }

data LocalConnectionState
  = LocalConnectionValid
  | LocalConnectionClosed
  | LocalConnectionFailed

newtype TransportInternals = TransportInternals (TVar TransportState)

-- | Create a new Transport exposing internal state.
--
-- Useful for testing and/or debugging purposes.
-- Should not be used in production. No guarantee as to the stability of the internals API.
createTransportExposeInternals :: IO (Transport, TransportInternals)
createTransportExposeInternals = do
  state <- newTVarIO $ TransportValid $ ValidTransportState
    { _localEndPoints = Map.empty
    , _nextLocalEndPointId = 0
    }
  return (Transport
    { newEndPoint    = apiNewEndPoint state
    , closeTransport = do
        -- transactions are splitted into smaller ones intentionally
        old <- atomically $ swapTVar state TransportClosed
        case old of
          TransportClosed -> return ()
          TransportValid tvst -> do
            forM_ (tvst ^. localEndPoints) $ \l -> do
              cons <- atomically $ whenValidLocalEndPointState l $ \lvst -> do
                writeTChan (localEndPointChannel l) EndPointClosed
                writeTVar  (localEndPointState l) LocalEndPointClosed
                return (lvst ^. connections)
              forM_ cons $ \con -> atomically $
                writeTVar (localConnectionState con) LocalConnectionClosed
    }, TransportInternals state)


-- | Create a new end point.
apiNewEndPoint :: TVar TransportState
               -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint state = handle (return . Left) $ atomically $ do
  chan <- newTChan
  (lep,addr) <- withValidTransportState state NewEndPointFailed $ \vst -> do
    lepState <- newTVar $ LocalEndPointValid $ ValidLocalEndPointState
      { _nextConnectionId = 1
      , _connections = Map.empty
      , _multigroups = Map.empty
      }
    let r = nextLocalEndPointId ^: (+ 1) $ vst
        addr = EndPointAddress . BSC.pack . show $ r ^. nextLocalEndPointId
        lep = LocalEndPoint
          { localEndPointAddress = addr
          , localEndPointChannel = chan
          , localEndPointState = lepState
          }
    writeTVar state (TransportValid $ localEndPointAt addr ^= Just lep $ r)
    return (lep, addr)
  return $ Right $ EndPoint
    { receive       = atomically $ do
        result <- tryReadTChan chan
        case result of
          Nothing -> do st <- readTVar (localEndPointState lep)
                        case st of
                          LocalEndPointClosed ->
                            throwSTM (userError "Channel is closed.")
                          LocalEndPointValid{} -> retry
          Just x -> return x
    , address       = addr
    , connect       = apiConnect addr state
    , closeEndPoint = apiCloseEndPoint state addr
    , newMulticastGroup     = return $ Left $ newMulticastGroupError
    , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
    }
  where
    -- see [Multicast] section
    newMulticastGroupError =
      TransportError NewMulticastGroupUnsupported "Multicast not supported"
    resolveMulticastGroupError =
      TransportError ResolveMulticastGroupUnsupported "Multicast not supported"

apiCloseEndPoint :: TVar TransportState -> EndPointAddress -> IO ()
apiCloseEndPoint state addr = atomically $ whenValidTransportState state $ \vst -> do

    forM_ (Map.toList $ _localEndPoints vst) $
      \(theirAddr, lep) -> do

        if theirAddr == addr
           then do
              old <- swapTVar (localEndPointState lep) LocalEndPointClosed
              case old of
                LocalEndPointClosed -> return ()
                LocalEndPointValid lepvst -> do
                  forM_ (Map.elems (lepvst ^. connections)) $ \lconn -> do
                    st <- swapTVar (localConnectionState lconn) LocalConnectionClosed
                    case st of
                      LocalConnectionClosed -> return ()
                      LocalConnectionFailed -> return ()
                      _ -> do
                        forM_ (vst ^. localEndPointAt (localConnectionRemoteAddress lconn)) $ \thep ->
                             whenValidLocalEndPointState thep $ \_ -> do
                                writeTChan (localEndPointChannel thep)
                                           (ConnectionClosed (localConnectionId lconn))
                  writeTChan (localEndPointChannel lep) EndPointClosed
                  writeTVar  (localEndPointState lep)    LocalEndPointClosed

            else do
              apiBreakConnection state addr theirAddr "remote endpoint disconnected"

    writeTVar state (TransportValid $ (localEndPoints ^: Map.delete addr) vst)

-- | Tear down functions that should be called in case if conncetion fails.
apiBreakConnection :: TVar TransportState
                   -> EndPointAddress
                   -> EndPointAddress
                   -> String
                   -> STM ()
apiBreakConnection state us them msg
  | us == them = return ()
  | otherwise  = whenValidTransportState state $ \vst -> do
      breakOne vst us them >> breakOne vst them us
  where
    breakOne vst a b = do
      forM_ (vst ^. localEndPointAt a) $ \lep ->
        whenValidLocalEndPointState lep $ \lepvst -> do
          let (cl, other) = Map.partitionWithKey (\(addr,_) _ -> addr == b)
                                                 (lepvst ^.connections)
          forM_ cl $ \c -> modifyTVar (localConnectionState c)
                                      (\x -> case x of
                                               LocalConnectionValid -> LocalConnectionFailed
                                               _ -> x)
          writeTChan (localEndPointChannel lep)
                     (ErrorEvent (TransportError (EventConnectionLost b) msg))
          writeTVar (localEndPointState lep)
                    (LocalEndPointValid $ (connections ^= other) lepvst)


-- | Create a new connection
apiConnect :: EndPointAddress
           -> TVar TransportState
           -> EndPointAddress
           -> Reliability
           -> ConnectHints
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect ourAddress state theirAddress _reliability _hints = do
    handle (return . Left) $ fmap Right $ atomically $ do
      (chan, lconn) <- do
        withValidTransportState state ConnectFailed $ \vst -> do
          ourlep <- case vst ^. localEndPointAt ourAddress of
                      Nothing ->
                        throwSTM $ TransportError ConnectFailed "Endpoint closed"
                      Just x  -> return x
          theirlep <- case vst ^. localEndPointAt theirAddress of
                        Nothing ->
                          throwSTM $ TransportError ConnectNotFound "Endpoint not found"
                        Just x  -> return x
          conid <- withValidLocalEndPointState theirlep ConnectFailed $ \lepvst -> do
            let r = nextConnectionId ^: (+ 1) $ lepvst
            writeTVar (localEndPointState theirlep) (LocalEndPointValid r)
            return (r ^. nextConnectionId)
          withValidLocalEndPointState ourlep ConnectFailed $ \lepvst -> do
            lconnState <- newTVar LocalConnectionValid
            let lconn = LocalConnection
                           { localConnectionId = conid
                           , localConnectionLocalAddress = ourAddress
                           , localConnectionRemoteAddress = theirAddress
                           , localConnectionState = lconnState
                           }
            writeTVar (localEndPointState ourlep)
                      (LocalEndPointValid $
                         connectionAt (theirAddress, conid) ^= lconn $ lepvst)
            return (localEndPointChannel theirlep, lconn)
      writeTChan chan $
        ConnectionOpened (localConnectionId lconn) ReliableOrdered ourAddress
      return $ Connection
        { send  = apiSend chan state lconn
        , close = apiClose chan state lconn
        }

-- | Send a message over a connection
apiSend :: TChan Event
        -> TVar TransportState
        -> LocalConnection
        -> [ByteString]
        -> IO (Either (TransportError SendErrorCode) ())
apiSend chan state lconn msg = handle handleFailure $ mapIOException sendFailed $
    atomically $ do
      connst <- readTVar (localConnectionState lconn)
      case connst of
        LocalConnectionValid -> do
          foldr seq () msg `seq`
            writeTChan chan (Received (localConnectionId lconn) msg)
          return $ Right ()
        LocalConnectionClosed -> do
          -- If the local connection was closed, check why.
          withValidTransportState state SendFailed $ \vst -> do
            let addr = localConnectionLocalAddress lconn
                mblep = vst ^. localEndPointAt addr
            case mblep of
              Nothing -> throwSTM $ TransportError SendFailed "Endpoint closed"
              Just lep -> do
                lepst <- readTVar (localEndPointState lep)
                case lepst of
                  LocalEndPointValid _ -> do
                    return $ Left $ TransportError SendClosed "Connection closed"
                  LocalEndPointClosed -> do
                    throwSTM $ TransportError SendFailed "Endpoint closed"
        LocalConnectionFailed -> return $
          Left $ TransportError SendFailed "Endpoint closed"
    where
      sendFailed = TransportError SendFailed . show
      handleFailure ex@(TransportError SendFailed reason) = atomically $ do
        apiBreakConnection state (localConnectionLocalAddress lconn)
                                 (localConnectionRemoteAddress lconn)
                                 reason
        return (Left ex)
      handleFailure ex = return (Left ex)

-- | Close a connection
apiClose :: TChan Event
         -> TVar TransportState
         -> LocalConnection
         -> IO ()
apiClose chan state lconn = do
  atomically $ do -- XXX: whenValidConnectionState
    connst <- readTVar (localConnectionState lconn)
    case connst of
      LocalConnectionValid -> do
        writeTChan chan $ ConnectionClosed (localConnectionId lconn)
        writeTVar (localConnectionState lconn) LocalConnectionClosed
        whenValidTransportState state $ \vst -> do
          let mblep = vst ^. localEndPointAt (localConnectionLocalAddress lconn)
              theirAddress = localConnectionRemoteAddress lconn
          forM_ mblep $ \lep ->
            whenValidLocalEndPointState lep $
              writeTVar (localEndPointState lep)
                . LocalEndPointValid
                . (connections ^: Map.delete (theirAddress, localConnectionId lconn))
      _ -> return ()

-- [Multicast]
-- Currently multicast implementation doesn't pass it's tests, so it
-- disabled. Here we have old code that could be improved, see GitHub ISSUE 5
-- https://github.com/haskell-distributed/network-transport-inmemory/issues/5

-- | Construct a multicast group
--
-- When the group is deleted some endpoints may still receive messages, but
-- subsequent calls to resolveMulticastGroup will fail. This mimicks the fact
-- that some multicast messages may still be in transit when the group is
-- deleted.
createMulticastGroup :: TVar TransportState
                     -> EndPointAddress
                     -> MulticastAddress
                     -> TVar (Set EndPointAddress)
                     -> MulticastGroup
createMulticastGroup state ourAddress groupAddress group = MulticastGroup
    { multicastAddress     = groupAddress
    , deleteMulticastGroup = atomically $
        whenValidTransportState state $ \vst -> do
          -- XXX best we can do given current broken API, which needs fixing.
          let lep = fromJust $ vst ^. localEndPointAt ourAddress
          modifyTVar' (localEndPointState lep) $ \lepst -> case lepst of
            LocalEndPointValid lepvst ->
              LocalEndPointValid $ multigroups ^: Map.delete groupAddress $ lepvst
            LocalEndPointClosed ->
              LocalEndPointClosed
    , maxMsgSize           = Nothing
    , multicastSend        = \payload -> atomically $
        withValidTransportState state SendFailed $ \vst -> do
          es <- readTVar group
          forM_ (Set.elems es) $ \ep -> do
            let ch = localEndPointChannel $ fromJust $ vst ^. localEndPointAt ep
            writeTChan ch (ReceivedMulticast groupAddress payload)
    , multicastSubscribe   = atomically $ modifyTVar' group $ Set.insert ourAddress
    , multicastUnsubscribe = atomically $ modifyTVar' group $ Set.delete ourAddress
    , multicastClose       = return ()
    }

-- | Create a new multicast group
_apiNewMulticastGroup :: TVar TransportState
                     -> EndPointAddress
                     -> IO (Either (TransportError NewMulticastGroupErrorCode) MulticastGroup)
_apiNewMulticastGroup state ourAddress = handle (return . Left) $ do
  group <- newTVarIO Set.empty
  groupAddr <- atomically $
    withValidTransportState state NewMulticastGroupFailed $ \vst -> do
      lep <- maybe (throwSTM $ TransportError NewMulticastGroupFailed "Endpoint closed")
                   return
                   (vst ^. localEndPointAt ourAddress)
      withValidLocalEndPointState lep NewMulticastGroupFailed $ \lepvst -> do
        let addr = MulticastAddress . BSC.pack . show . Map.size $ lepvst ^. multigroups
        writeTVar (localEndPointState lep) (LocalEndPointValid $ multigroupAt addr ^= group $ lepvst)
        return addr
  return . Right $ createMulticastGroup state ourAddress groupAddr group

-- | Resolve a multicast group
_apiResolveMulticastGroup :: TVar TransportState
                         -> EndPointAddress
                         -> MulticastAddress
                         -> IO (Either (TransportError ResolveMulticastGroupErrorCode) MulticastGroup)
_apiResolveMulticastGroup state ourAddress groupAddress = handle (return . Left) $ atomically $
    withValidTransportState state ResolveMulticastGroupFailed $ \vst -> do
      lep <- maybe (throwSTM $ TransportError ResolveMulticastGroupFailed "Endpoint closed")
                   return
                   (vst ^. localEndPointAt ourAddress)
      withValidLocalEndPointState lep ResolveMulticastGroupFailed $ \lepvst -> do
          let group = lepvst ^. (multigroups >>> DAC.mapMaybe groupAddress)
          case group of
            Nothing ->
              return . Left $
                TransportError ResolveMulticastGroupNotFound
                  ("Group " ++ show groupAddress ++ " not found")
            Just mvar ->
              return . Right $ createMulticastGroup state ourAddress groupAddress mvar

--------------------------------------------------------------------------------
-- Lens definitions                                                           --
--------------------------------------------------------------------------------

nextLocalEndPointId :: Accessor ValidTransportState Int
nextLocalEndPointId = accessor _nextLocalEndPointId (\eid st -> st{ _nextLocalEndPointId = eid} )

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\leps st -> st { _localEndPoints = leps })

nextConnectionId :: Accessor ValidLocalEndPointState ConnectionId
nextConnectionId = accessor _nextConnectionId (\cid st -> st { _nextConnectionId = cid })

connections :: Accessor ValidLocalEndPointState (Map (EndPointAddress,ConnectionId) LocalConnection)
connections = accessor _connections (\conns st -> st { _connections = conns })

multigroups :: Accessor ValidLocalEndPointState (Map MulticastAddress (TVar (Set EndPointAddress)))
multigroups = accessor _multigroups (\gs st -> st { _multigroups = gs })

at :: Ord k => k -> String -> Accessor (Map k v) v
at k err = accessor (Map.findWithDefault (error err) k) (Map.insert k)

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr

connectionAt :: (EndPointAddress, ConnectionId) -> Accessor ValidLocalEndPointState LocalConnection
connectionAt addr = connections >>> at addr "Invalid connection"

multigroupAt :: MulticastAddress -> Accessor ValidLocalEndPointState (TVar (Set EndPointAddress))
multigroupAt addr = multigroups >>> at addr "Invalid multigroup"

---------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------

-- | LocalEndPoint state deconstructor.
overValidLocalEndPointState :: LocalEndPoint -> STM a -> (ValidLocalEndPointState -> STM a) -> STM a
overValidLocalEndPointState lep fallback action = do
  lepst <- readTVar (localEndPointState lep)
  case lepst of
    LocalEndPointValid lepvst -> action lepvst
    _ -> fallback

-- | Specialized deconstructor that throws TransportError in case of Closed state
withValidLocalEndPointState :: (Typeable e, Show e) => LocalEndPoint -> e -> (ValidLocalEndPointState -> STM a) -> STM a
withValidLocalEndPointState lep ex = overValidLocalEndPointState lep (throw $ TransportError ex "EndPoint closed")

-- | Specialized deconstructor that do nothing in case of failure
whenValidLocalEndPointState :: Monoid m => LocalEndPoint -> (ValidLocalEndPointState -> STM m) -> STM m
whenValidLocalEndPointState lep = overValidLocalEndPointState lep (return mempty)

overValidTransportState :: TVar TransportState -> STM a -> (ValidTransportState -> STM a) -> STM a
overValidTransportState ts fallback action = do
  tsst <- readTVar ts
  case  tsst of
    TransportValid tsvst -> action tsvst
    _ -> fallback

withValidTransportState :: (Typeable e, Show e) => TVar TransportState -> e -> (ValidTransportState -> STM a) -> STM a
withValidTransportState ts ex = overValidTransportState ts (throw $ TransportError ex "Transport closed")

whenValidTransportState :: Monoid m => TVar TransportState -> (ValidTransportState -> STM m) -> STM m
whenValidTransportState ts = overValidTransportState ts (return mempty)
