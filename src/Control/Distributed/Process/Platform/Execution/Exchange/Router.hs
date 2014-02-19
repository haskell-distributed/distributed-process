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

-- | A simple API for /routing/, using a custom exchange type.
module Control.Distributed.Process.Platform.Execution.Exchange.Router
  ( -- * Types
    HeaderName
  , Binding(..)
  , Bindable
  , BindingSelector
  , RelayType(..)
    -- * Starting a Router
  , router
  , supervisedRouter
  , supervisedRouterRef
    -- * Client (Publishing) API
  , route
  , routeMessage
    -- * Routing via message/binding keys
  , messageKeyRouter
  , bindKey
    -- * Routing via message headers
  , headerContentRouter
  , bindHeader
  ) where

import Control.DeepSeq (NFData)
import Control.Distributed.Process
  ( Process
  , ProcessMonitorNotification(..)
  , ProcessId
  , monitor
  , handleMessage
  , unsafeWrapMessage
  )
import qualified Control.Distributed.Process as P
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Platform.Execution.Exchange.Internal
  ( startExchange
  , startSupervised
  , configureExchange
  , Message(..)
  , Exchange
  , ExchangeType(..)
  , post
  , postMessage
  , applyHandlers
  )
import Control.Distributed.Process.Platform.Internal.Primitives
  ( deliver
  , Resolvable(..)
  )
import Control.Distributed.Process.Platform.Supervisor (SupervisorPid)
import Data.Binary
import Data.Foldable (forM_)
import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import Data.HashSet (HashSet)
import qualified Data.HashSet as Set
import Data.Typeable (Typeable)
import GHC.Generics

type HeaderName = String

-- | The binding key used by the built-in key and header based
-- routers.
data Binding =
    BindKey    { bindingKey :: !String }
  | BindHeader { bindingKey :: !String
               , headerName :: !HeaderName
               }
  | BindNone
  deriving (Typeable, Generic, Eq, Show)
instance Binary Binding where
instance NFData Binding where
instance Hashable Binding where

-- | Things that can be used as binding keys in a router.
class (Hashable k, Eq k, Serializable k) => Bindable k
instance (Hashable k, Eq k, Serializable k) => Bindable k

-- | Used to convert a 'Message' into a 'Bindable' routing key.
type BindingSelector k = (Message -> Process k)

-- | Given to a /router/ to indicate whether clients should
-- receive 'Message' payloads only, or the whole 'Message' object
-- itself.
data RelayType = PayloadOnly | WholeMessage

data State k = State { bindings  :: !(HashMap k (HashSet ProcessId))
                     , selector  :: !(BindingSelector k)
                     , relayType :: !RelayType
                     }

type Router k = ExchangeType (State k)

--------------------------------------------------------------------------------
-- Starting/Running the Exchange                                              --
--------------------------------------------------------------------------------

-- | A router that matches on a 'Message' 'key'. To bind a client @Process@ to
-- such an exchange, use the 'bindKey' function.
messageKeyRouter :: RelayType -> Process Exchange
messageKeyRouter t = router t matchOnKey -- (return . BindKey . key)
  where
    matchOnKey :: Message -> Process Binding
    matchOnKey m = return $ BindKey (key m)

-- | A router that matches on a specific (named) header. To bind a client
-- @Process@ to such an exchange, use the 'bindHeader' function.
headerContentRouter :: RelayType -> HeaderName -> Process Exchange
headerContentRouter t n = router t (checkHeaders n)
  where
    checkHeaders hn Message{..} = do
      case Map.lookup hn (Map.fromList headers) of
        Nothing -> return BindNone
        Just hv -> return $ BindHeader hn hv

-- | Defines a /router/ exchange. The 'BindingSelector' is used to construct
-- a binding (i.e., an instance of the 'Bindable' type @k@) for each incoming
-- 'Message'. Such bindings are matched against bindings stored in the exchange.
-- Clients of a /router/ exchange are identified by a binding, mapped to
-- one or more 'ProcessId's.
--
-- The format of the bindings, nature of their storage and mechanism for
-- submitting new bindings is implementation dependent (i.e., will vary by
-- exchange type). For example, the 'messageKeyRouter' and 'headerContentRouter'
-- implementations both use the 'Binding' data type, which can represent a
-- 'Message' key or a 'HeaderName' and content. As with all custom exchange
-- types, bindings should be submitted by evaluating 'configureExchange' with
-- a suitable data type.
--
router :: (Bindable k) => RelayType -> BindingSelector k -> Process Exchange
router t s = routerT t s >>= startExchange

supervisedRouterRef :: Bindable k
                    => RelayType
                    -> BindingSelector k
                    -> SupervisorPid
                    -> Process (ProcessId, P.Message)
supervisedRouterRef t sel spid = do
  ex <- supervisedRouter t sel spid
  Just pid <- resolve ex
  return (pid, unsafeWrapMessage ex)

-- | Defines a /router/ that can be used in a supervision tree.
supervisedRouter :: Bindable k
                 => RelayType
                 -> BindingSelector k
                 -> SupervisorPid
                 -> Process Exchange
supervisedRouter t sel spid =
  routerT t sel >>= \t' -> startSupervised t' spid

routerT :: Bindable k
        => RelayType
        -> BindingSelector k
        -> Process (Router k)
routerT t s = do
  return $ ExchangeType { name        = "Router"
                        , state       = State Map.empty s t
                        , configureEx = apiConfigure
                        , routeEx     = apiRoute
                        }

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

-- | Add a binding (for the calling process) to a 'messageKeyRouter' exchange.
bindKey :: String -> Exchange -> Process ()
bindKey k ex = do
  self <- P.getSelfPid
  configureExchange ex (self, BindKey k)

-- | Add a binding (for the calling process) to a 'headerContentRouter' exchange.
bindHeader :: HeaderName -> String -> Exchange -> Process ()
bindHeader n v ex = do
  self <- P.getSelfPid
  configureExchange ex (self, BindHeader v n)

-- | Send a 'Serializable' message to the supplied 'Exchange'. The given datum
-- will be converted to a 'Message', with the 'key' set to @""@ and the
-- 'headers' to @[]@.
--
-- The routing behaviour will be dependent on the choice of 'BindingSelector'
-- given when initialising the /router/.
route :: Serializable m => Exchange -> m -> Process ()
route = post

-- | Send a 'Message' to the supplied 'Exchange'.
-- The routing behaviour will be dependent on the choice of 'BindingSelector'
-- given when initialising the /router/.
routeMessage :: Exchange -> Message -> Process ()
routeMessage = postMessage

--------------------------------------------------------------------------------
-- Exchage Definition/State & API Handlers                                    --
--------------------------------------------------------------------------------

apiRoute :: forall k. Bindable k
         => State k
         -> Message
         -> Process (State k)
apiRoute st@State{..} msg = do
  binding <- selector msg
  case Map.lookup binding bindings of
    Nothing -> return st
    Just bs -> forM_ bs (fwd relayType msg) >> return st
  where
    fwd WholeMessage m = deliver m
    fwd PayloadOnly  m = P.forward (payload m)

-- TODO: implement 'unbind' ???
-- TODO: apiConfigure currently leaks memory if clients die (we don't cleanup)

apiConfigure :: forall k. Bindable k
             => State k
             -> P.Message
             -> Process (State k)
apiConfigure st msg = do
  applyHandlers st msg $ [ \m -> handleMessage m (createBinding st)
                         , \m -> handleMessage m (handleMonitorSignal st)
                         ]
  where
    createBinding s@State{..} (pid, bind) = do
      case Map.lookup bind bindings of
        Nothing -> do _ <- monitor pid
                      return $ s { bindings = newBind bind pid bindings }
        Just ps -> return $ s { bindings = addBind bind pid bindings ps }

    newBind b p bs = Map.insert b (Set.singleton p) bs
    addBind b' p' bs' ps = Map.insert b' (Set.insert p' ps) bs'

    handleMonitorSignal s@State{..} (ProcessMonitorNotification _ p _) =
      let bs  = bindings
          bs' = Map.foldlWithKey' (\a k v -> Map.insert k (Set.delete p v) a) bs bs
      in return $ s { bindings = bs' }

