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
-- Module      :  Control.Distributed.Process.Platform.Execution.Exchange.Router
-- Copyright   :  (c) Tim Watson 2012 - 2014
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainer  :  Tim Watson <watson.timothy@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Execution.Exchange.Router where

import Control.DeepSeq (NFData)
import Control.Distributed.Process
  ( Process
  , MonitorRef
  , ProcessMonitorNotification(..)
  , ProcessId
  , monitor
  , handleMessage
  )
import qualified Control.Distributed.Process as P
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Platform.Execution.Exchange.Internal
  ( startExchange
  , startSupervisedExchange
  , configureExchange
  , Message(..)
  , Exchange
  , ExchangeType(..)
  , post
  , postMessage
  )
import Control.Distributed.Process.Platform.Internal.Primitives
  ( deliver
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

data BindOk = BindOk
  deriving (Typeable, Generic)
instance Binary BindOk where
instance NFData BindOk where

data BindFail = BindFail !String
  deriving (Typeable, Generic)
instance Binary BindFail where
instance NFData BindFail where

type HeaderName = String
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

class (Hashable k, Eq k, Serializable k) => Bindable k
instance (Hashable k, Eq k, Serializable k) => Bindable k

type Bindings k = HashMap k (HashSet ProcessId)

type BindingSelector k = (Message -> Process k)

data RelayType = PayloadOnly | WholeMessage

data State k = State { bindings  :: !(Bindings k)
                     , selector  :: !(BindingSelector k)
                     , relayType :: !RelayType
                     }

type Router k = ExchangeType (State k)

--------------------------------------------------------------------------------
-- Starting/Running the Exchange                                              --
--------------------------------------------------------------------------------

messageKeyRouter :: RelayType -> Process Exchange
messageKeyRouter t = router t matchOnKey -- (return . BindKey . key)
  where
    matchOnKey :: Message -> Process Binding
    matchOnKey m = return $ BindKey (key m)

headerContentRouter :: RelayType -> HeaderName -> Process Exchange
headerContentRouter t n = router t (checkHeaders n)
  where
    checkHeaders hn Message{..} = do
      case Map.lookup hn (Map.fromList headers) of
        Nothing -> return BindNone
        Just hv -> return $ BindHeader hn hv

router :: (Bindable k) => RelayType -> BindingSelector k -> Process Exchange
router t s = routerT t s >>= startExchange

supervisedRouter :: Bindable k
                 => RelayType
                 -> BindingSelector k
                 -> SupervisorPid
                 -> Process Exchange
supervisedRouter t sel spid =
  routerT t sel >>= \t' -> startSupervisedExchange t' spid

routerT :: Bindable k
        => RelayType
        -> BindingSelector k
        -> Process (Router k)
routerT t s = do
  return $ ExchangeType { name      = "Router"
                        , state     = State Map.empty s t
                        , configure = apiConfigure
                        , route     = apiRoute
                        }

--------------------------------------------------------------------------------
-- Client Facing API                                                          --
--------------------------------------------------------------------------------

bindKey :: String -> Exchange -> Process ()
bindKey k ex = do
  self <- P.getSelfPid
  configureExchange ex (self, BindKey k)

bindHeader :: HeaderName -> String -> Exchange -> Process ()
bindHeader n v ex = do
  self <- P.getSelfPid
  configureExchange ex (self, BindHeader v n)

route :: Serializable m => Exchange -> m -> Process ()
route = post

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
  return . maybe st id =<< handleMessage msg (createBinding st)
  where
    createBinding s@State{..} (pid, bind) = do
      case Map.lookup bind bindings of
        Nothing -> return $ s { bindings = newBind bind pid bindings }
        Just ps -> return $ s { bindings = addBind bind pid bindings ps }

    newBind b p bs = Map.insert b (Set.singleton p) bs

    addBind b' p' bs' ps = Map.insert b' (Set.insert p' ps) bs'

