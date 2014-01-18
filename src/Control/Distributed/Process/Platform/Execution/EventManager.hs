{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE ImpredicativeTypes        #-}

module Control.Distributed.Process.Platform.Execution.EventManager where

import Control.Distributed.Process hiding (Message, link)
import Control.Distributed.Process.Platform.Execution.Exchange.Broadcast
  ( broadcastExchange
  , broadcastClient
  , Exchange
  , Message(..)
  , post
  , link
  )
import qualified Control.Distributed.Process.Platform.Execution.Exchange.Broadcast as B (monitor)
import Control.Distributed.Process.Platform.Internal.Primitives
import Control.Distributed.Process.Platform.Internal.Unsafe
  ( InputStream
  , matchInputStream
  )
import Control.Distributed.Process.Serializable hiding (SerializableDict)

newtype EventManager = EventManager { ex :: Exchange }

instance Resolvable EventManager where
  resolve = resolve . ex

start :: Process EventManager
start = broadcastExchange >>= return . EventManager

monitor :: EventManager -> Process MonitorRef
monitor = B.monitor . ex

notify :: Serializable a => EventManager -> a -> Process ()
notify = post . ex

addHandler :: forall s a. Serializable a
           => EventManager
           -> (s -> a -> Process s)
           -> s
           -> Process ProcessId
addHandler m h s = spawnLocal (newHandler (ex m) h s)

newHandler :: forall s a. Serializable a
           => Exchange
           -> (s -> a -> Process s)
           -> s
           -> Process ()
newHandler ex handler state = do
  link ex
  is <- broadcastClient ex
  listen is handler state

listen :: forall s a. Serializable a
       => InputStream Message
       -> (s -> a -> Process s)
       -> s
       -> Process ()
listen inStream handler state = do
  receiveWait [ matchInputStream inStream ] >>= handleEvent inStream handler state
  where
    handleEvent is h s Message{..} = do
      r <- handleMessage payload (h s)
      let s2 = case r of
                 Nothing -> s
                 Just s' -> s'
      listen is h s2

