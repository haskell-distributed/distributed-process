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

-- | Internal Exchange Implementation
module Control.Distributed.Process.Platform.Execution.Exchange.Internal where

import Control.Concurrent.MVar (MVar, takeMVar, putMVar, newEmptyMVar)
import Control.DeepSeq (NFData)
import Control.Distributed.Process
  ( Process
  , MonitorRef
  , ProcessMonitorNotification(..)
  , ProcessId
  , liftIO
  , spawnLocal
  , unsafeWrapMessage
  )
import qualified Control.Distributed.Process as P (Message, link, monitor, unmonitor)
import Control.Distributed.Process.Serializable hiding (SerializableDict)
import Control.Distributed.Process.Platform.Internal.Types
  ( ExitReason(..)
  , Resolvable(..)
  , NFSerializable
  , Channel
  , ServerDisconnected(..)
  )
import Control.Distributed.Process.Platform.Internal.Primitives
  ( Observable(..)
  )
import Control.Distributed.Process.Platform.ManagedProcess
  ( call
  , channelControlPort
  , handleControlChan
  , handleInfo
  , handleRaw
  , continue
  , defaultProcess
  , UnhandledMessagePolicy(..)
  , InitHandler
  , InitResult(..)
  , ProcessAction
  , ProcessDefinition(..)
  , ControlChannel
  , ControlPort
  )
import qualified Control.Distributed.Process.Platform.ManagedProcess as MP
  ( chanServe
  )
import Control.Distributed.Process.Platform.ManagedProcess.UnsafeClient
  ( sendControlMessage
  )
import Control.Distributed.Process.Platform.ManagedProcess.Server
  ( stop
  )
import Control.Distributed.Process.Platform.Supervisor (SupervisorPid)
import Control.Distributed.Process.Platform.Time (Delay(Infinity))
import Data.Binary
import Data.Typeable (Typeable)
import GHC.Generics
import Prelude hiding (drop)

{- [design notes]

Messages are sent to exchanges and forwarded to clients. An exchange
is parameterised by its routing mechanism, which is responsible for
maintaining its own client state and selecting the clients to which
messages are forwarded.

-}

-- | Opaque handle to an exchange.
--
data Exchange = Exchange { pid   :: !ProcessId
                         , cchan :: !(ControlPort ControlMessage)
                         , xType :: !String
                         } deriving (Typeable, Generic, Eq)
instance Binary Exchange where
instance Show Exchange where
  show Exchange{..} = (xType ++ ":" ++ (show pid))

instance Resolvable Exchange where
  resolve = return . Just . pid

instance Observable Exchange MonitorRef ProcessMonitorNotification where
  observe   = P.monitor . pid
  unobserve = P.unmonitor
  observableFrom ref (ProcessMonitorNotification ref' _ r) =
    return $ if ref' == ref then Just r else Nothing

link :: Exchange -> Process ()
link = P.link . pid

monitor :: Exchange -> Process MonitorRef
monitor = P.monitor . pid

-- we communicate with exchanges using control channels
sendCtrlMsg :: Exchange -> ControlMessage -> Process ()
sendCtrlMsg Exchange{..} = sendControlMessage cchan

-- | Messages sent to an exchange can optionally provide a routing
-- key and a list of (key, value) headers in addition to the underlying
-- payload.
data Message = Message { key     :: !String
                       , headers :: ![(String, String)]
                       , payload :: !P.Message
                       } deriving (Typeable, Generic, Show)
instance Binary Message where
instance NFData Message where

data ControlMessage =
    Configure !P.Message
  | Post      !Message
    deriving (Typeable, Generic)
instance Binary ControlMessage where
instance NFData ControlMessage where

-- | Different exchange types are defined using record syntax.
-- The 'configure' and 'route' API functions are called during the exchange
-- lifecycle when incoming traffic arrives. Configuration messages are
-- completely arbitrary types and the exchange type author is entirely
-- responsible for decoding them. Messages posted to the exchange (see the
-- 'Message' data type) are passed to the 'route' API function along with the
-- exchange type's own internal state. Both API functions return a new
-- (potentially updated) state and run in the @Process@ monad.
--
data ExchangeType s =
  ExchangeType { name      :: String
               , state     :: s
               , configure :: s -> P.Message -> Process s
               , route     :: s -> Message -> Process s
               }

--------------------------------------------------------------------------------
-- Starting/Running an Exchange                                               --
--------------------------------------------------------------------------------

startExchange :: forall s. ExchangeType s -> Process Exchange
startExchange = doStart Nothing

startSupervisedExchange :: forall s . ExchangeType s
                        -> SupervisorPid
                        -> Process Exchange
startSupervisedExchange t s = doStart (Just s) t

doStart :: Maybe SupervisorPid -> ExchangeType s -> Process Exchange
doStart mSp t = do
  cchan <- liftIO $ newEmptyMVar
  spawnLocal (maybeLink mSp >> runExchange t cchan) >>= \pid -> do
    cc <- liftIO $ takeMVar cchan
    return $ Exchange pid cc (name t)
  where
    maybeLink Nothing   = return ()
    maybeLink (Just p') = P.link p'

runExchange :: forall s.
               ExchangeType s
            -> MVar (ControlPort ControlMessage)
            -> Process ()
runExchange t tc = MP.chanServe t exInit (processDefinition t tc)

exInit :: forall s. InitHandler (ExchangeType s) (ExchangeType s)
exInit t = return $ InitOk t Infinity

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

post :: Serializable a => Exchange -> a -> Process ()
post ex msg = postMessage ex $ Message "" [] (unsafeWrapMessage msg)

postMessage :: Exchange -> Message -> Process ()
postMessage ex msg = msg `seq` sendCtrlMsg ex $ Post msg

configureExchange :: Serializable m => Exchange -> m -> Process ()
configureExchange e m = sendCtrlMsg e $ Configure (unsafeWrapMessage m)

--------------------------------------------------------------------------------
-- Process Definition/State & API Handlers                                    --
--------------------------------------------------------------------------------

processDefinition :: forall s.
                     ExchangeType s
                  -> MVar (ControlPort ControlMessage)
                  -> ControlChannel ControlMessage
                  -> Process (ProcessDefinition (ExchangeType s))
processDefinition _ tc cc = do
  liftIO $ putMVar tc $ channelControlPort cc
  return $
    defaultProcess {
        apiHandlers  = [ handleControlChan cc handleControlMessage ]
      , infoHandlers = [ handleInfo handleMonitor
                       , handleRaw convertToCC
                       ]
      } :: Process (ProcessDefinition (ExchangeType s))

handleMonitor :: forall s.
                 ExchangeType s
              -> ProcessMonitorNotification
              -> Process (ProcessAction (ExchangeType s))
handleMonitor ex m = do
  liftIO $ putStrLn "handle monitor signal!"
  handleControlMessage ex (Configure (unsafeWrapMessage m))

convertToCC :: forall s.
               ExchangeType s
            -> P.Message
            -> Process (ProcessAction (ExchangeType s))
convertToCC ex msg = do
  liftIO $ putStrLn "convert to cc"
  handleControlMessage ex (Post $ Message "" [] msg)

handleControlMessage :: forall s.
                        ExchangeType s
                     -> ControlMessage
                     -> Process (ProcessAction (ExchangeType s))
handleControlMessage ex@ExchangeType{..} cm =
  let action = case cm of
                 Configure msg -> configure state msg
                 Post      msg -> route state msg
  in action >>= \s -> continue $ ex { state = s }

