{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE PatternGuards         #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE EmptyDataDecls        #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ImpredicativeTypes    #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Execution.Exchange.Broadcast
-- Copyright   :  (c) Tim Watson 2012 - 2014
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Execution.Exchange.Broadcast
  (
    broadcastExchange
  , supervisedBroadcastExchange
  , broadcastClient
  , BroadcastExchange
    -- re-exported for convenience
  , Exchange
  , Message(..)
  , post
  , link
  , monitor
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TChan
  ( TChan
  , newBroadcastTChanIO
  , dupTChan
  , readTChan
  , writeTChan
  )
import Control.DeepSeq (NFData)
import Control.Distributed.Process
  ( Process
  , MonitorRef
  , ProcessMonitorNotification(..)
  , ProcessId
  , SendPort
  , processNodeId
  , getSelfPid
  , getSelfNode
  , liftIO
  , newChan
  , sendChan
  , unsafeSend
  , unsafeSendChan
  , receiveWait
  , match
  , matchIf
  , die
  , handleMessage
  , Match
  )
import qualified Control.Distributed.Process as P
import Control.Distributed.Process.Serializable()
import Control.Distributed.Process.Platform.Execution.Exchange.Internal
  ( startExchange
  , startSupervisedExchange
  , configureExchange
  , Message(..)
  , Exchange(..)
  , ExchangeType(..)
  , post
  , link
  , monitor
  )
import Control.Distributed.Process.Platform.Internal.Types
  ( Channel
  , ServerDisconnected(..)
  )
import Control.Distributed.Process.Platform.Internal.Unsafe -- see [note: pcopy]
  ( PCopy
  , pCopy
  , pUnwrap
  , matchChanP
  , InputStream(Null)
  , newInputStream
  )
import Control.Distributed.Process.Platform.Supervisor (SupervisorPid)
import Control.Monad (forM_, void)
import Data.Accessor
  ( Accessor
  , accessor
  , (^:)
  )
import Data.Binary
import qualified Data.Foldable as Foldable (toList)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Typeable (Typeable)
import GHC.Generics

-- newtype RoutingTable r =
--  RoutingTable { routes :: (Map String (Map ProcessId r)) }

-- [note: BindSTM, BindPort and safety]
-- We keep these two /bind types/ separate, since only one of them
-- is truly serializable. The risk of unifying them is that at some
-- later time a maintainer might not realise that BindSTM cannot be
-- sent over the wire due to our use of PCopy.
--

data BindPort = BindPort { portClient :: !ProcessId
                         , portSend   :: !(SendPort Message)
                         } deriving (Typeable, Generic)
instance Binary BindPort where
instance NFData BindPort where

data BindSTM =
    BindSTM  { stmClient :: !ProcessId
             , stmSend   :: !(SendPort (PCopy (InputStream Message)))
             } deriving (Typeable)
{-  | forall r. (Routable r) =>
    BindR    { client :: !ProcessId
             , key    :: !String
             , chanC  :: !r
             }
  deriving (Typeable, Generic)
-}

data OutputStream =
    WriteChan (SendPort Message)
  | WriteSTM  (Message -> STM ())
--  | WriteP    ProcessId
  | NoWrite
  deriving (Typeable)

data Binding = Binding { outputStream :: !OutputStream
                       , inputStream  :: !(InputStream Message)
                       } deriving (Typeable)

data BindOk = BindOk
  deriving (Typeable, Generic)
instance Binary BindOk where
instance NFData BindOk where

data BindFail = BindFail !String
  deriving (Typeable, Generic)
instance Binary BindFail where
instance NFData BindFail where

type BroadcastClients = Map ProcessId Binding
data BroadcastEx =
  BroadcastEx { _routingTable   :: !BroadcastClients
              , channel         :: !(TChan Message)
              }

type BroadcastExchange = ExchangeType BroadcastEx

--------------------------------------------------------------------------------
-- Starting/Running the Exchange                                              --
--------------------------------------------------------------------------------

broadcastExchange :: Process Exchange
broadcastExchange = broadcastExchangeT >>= startExchange

supervisedBroadcastExchange :: SupervisorPid -> Process Exchange
supervisedBroadcastExchange spid =
  broadcastExchangeT >>= \t -> startSupervisedExchange t spid

broadcastExchangeT :: Process BroadcastExchange
broadcastExchangeT = do
  ch <- liftIO newBroadcastTChanIO
  return $ ExchangeType { name      = "BroadcastExchange"
                        , state     = BroadcastEx Map.empty ch
                        , configure = apiConfigure
                        , route     = apiRoute
                        }

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

broadcastClient :: Exchange -> Process (InputStream Message)
broadcastClient ex@Exchange{..} = do
  myNode <- getSelfNode
  us     <- getSelfPid
  if processNodeId pid == myNode -- see [note: pcopy]
     then do (sp, rp) <- newChan :: Process (Channel (PCopy (InputStream Message)))
             configureExchange ex $ pCopy (BindSTM us sp)
             mRef <- P.monitor pid
             P.finally (receiveWait [ matchChanP rp, handleServerFailure mRef ])
                       (P.unmonitor mRef)
     else do (sp, rp) <- newChan :: Process (Channel Message)
             configureExchange ex $ BindPort us sp
             mRef <- P.monitor pid
             P.finally (receiveWait [
                           match (\(_ :: BindOk)   -> return $ newInputStream $ Left rp)
                         , match (\(f :: BindFail) -> die f)
                         , handleServerFailure mRef
                         ])
                       (P.unmonitor mRef)

--------------------------------------------------------------------------------
-- Exchage Definition/State & API Handlers                                    --
--------------------------------------------------------------------------------

apiRoute :: BroadcastEx -> Message -> Process BroadcastEx
apiRoute ex@BroadcastEx{..} msg = do
  liftIO $ putStrLn "apiRoute is running!"
  liftIO $ atomically $ writeTChan channel msg
  forM_ (Foldable.toList _routingTable) $ routeToClient msg
  return ex
  where
    routeToClient m b = writeToStream (outputStream b) m

apiConfigure :: BroadcastEx -> P.Message -> Process BroadcastEx
apiConfigure ex msg = do
  -- for unsafe / non-serializable message passing hacks, see [note: pcopy]
  liftIO $ putStrLn "Handling Configuration Change"
  first ex msg $ [ \m -> handleMessage m (handleBindPort ex)
                 , \m -> handleBindSTM ex m
                 , \m -> handleMessage m (handleMonitorSignal ex)
                 , (const $ return $ Just ex)
                 ]
  where
    handleMonitorSignal bx (ProcessMonitorNotification _ p _) =
      return $ (routingTable ^: Map.delete p) bx

    handleBindSTM ex'@BroadcastEx{..} msg' = do
      bind' <- pUnwrap msg' :: Process (Maybe BindSTM) -- see [note: pcopy]
      case bind' of
        Nothing -> return Nothing
        Just s  -> do
          let binding = lookupBinding ex' (stmClient s)
          case binding of
            Nothing -> createBinding ex' s >>= \ex'' -> handleBindSTM ex'' msg'
            Just b  -> sendBinding (stmSend s) b >> return (Just ex')

    createBinding bEx'@BroadcastEx{..} BindSTM{..} = do
      void $ P.monitor stmClient
      nch <- liftIO $ atomically $ dupTChan channel
      let istr = newInputStream $ Right (readTChan nch)
      let ostr = NoWrite -- we write to our own channel, not the broadcast
      let bnd = Binding ostr istr
      return $ (routingTable ^: Map.insert stmClient bnd) bEx'

    sendBinding sp' bs = unsafeSendChan sp' $ pCopy (inputStream bs)

    handleBindPort :: BroadcastEx -> BindPort -> Process BroadcastEx
    handleBindPort x@BroadcastEx{..} BindPort{..} = do
      let binding = lookupBinding x portClient
      case binding of
        Just _  -> unsafeSend portClient (BindFail "DuplicateBinding") >> return x
        Nothing -> do
          let istr = Null
          let ostr = WriteChan portSend
          let bound = Binding ostr istr
          void $ P.monitor portClient
          unsafeSend portClient BindOk
          return $ (routingTable ^: Map.insert portClient bound) x

    lookupBinding BroadcastEx{..} k = Map.lookup k $ _routingTable

{- [note: pcopy]

We rely on risky techniques here, in order to allow for sharing useful
data that is not really serializable. For Cloud Haskell generally, this is
a bad idea, since we want message passing to work both locally and in a
distributed setting. In this case however, what we're really attempting is
an optimisation, since we only use unsafe PCopy based techniques when dealing
with exchange clients residing on our (local) node.

The PCopy mechanism is defined in the (aptly named) "Unsafe" module.

-}

-- TODO: move handleServerFailure into Primitives.hs

writeToStream :: OutputStream -> Message -> Process ()
writeToStream (WriteChan sp) = sendChan sp  -- see [note: safe remote send]
writeToStream (WriteSTM stm) = liftIO . atomically . stm
writeToStream NoWrite        = const $ return ()
{-# INLINE writeToStream #-}

{- [note: safe remote send]

Although we go to great lengths here to avoid serialization and/or copying
overheads, there are some activities for which we prefer to play it safe.
Chief among these is delivering messages to remote clients. Thankfully, our
unsafe @sendChan@ primitive will crash the caller/sender if there are any
encoding problems, however it is only because we /know/ for certain that
our recipient is remote, that we've chosen to write via a SendPort in the
first place! It makes sense therefore, to use the safe @sendChan@ operation
here, since for a remote call we /cannot/ avoid the overhead of serialization
anyway.

-}

handleServerFailure :: MonitorRef -> Match (InputStream Message)
handleServerFailure mRef =
  matchIf (\(ProcessMonitorNotification r _ _) -> r == mRef)
          (\(ProcessMonitorNotification _ _ d) -> die $ ServerDisconnected d)

first :: BroadcastEx
      -> P.Message
      -> [P.Message -> Process (Maybe BroadcastEx)]
      -> Process BroadcastEx
first e _ []     = return e
first e m (f:fs) = do
  r <- f m
  case r of
    Nothing -> first e m fs
    Just r' -> return r'

routingTable :: Accessor BroadcastEx BroadcastClients
routingTable = accessor _routingTable (\r e -> e { _routingTable = r })

