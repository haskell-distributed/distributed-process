{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RankNTypes  #-}
{-# LANGUAGE StaticPointers #-}
module Control.Distributed.Process.Internal.Closure.BuiltIn
  ( -- * Static dictionaries and associated operations
    sdictUnit
  , sdictProcessId
  , sdictSendPort
    -- * Some static values
  , sndStatic
    -- * The CP type and associated combinators
  , CP
  , idCP
  , splitCP
  , returnCP
  , bindCP
  , seqCP
    -- * CP versions of Cloud Haskell primitives
  , decodeProcessIdStatic
  , cpLink
  , cpUnlink
  , cpRelay
  , cpSend
  , cpExpect
  , cpNewChan
    -- * Support for some CH operations
  , cpDelayed
  ) where

import Data.ByteString.Lazy (ByteString)
import Data.Binary (decode, encode)
import Data.Typeable (Typeable)
import GHC.StaticPtr (StaticPtr)
import Control.Distributed.Static
  ( Closure
  , closure
  , closureApplyStatic
  , closureApply
  )
import Control.Distributed.Process.Serializable
  ( SerializableDict(..)
  , Serializable
  )
import Control.Distributed.Process.Internal.Types
  ( Process
  , ProcessId
  , SendPort
  , ReceivePort
  , ProcessMonitorNotification(ProcessMonitorNotification)
  )
import Control.Distributed.Process.Internal.Primitives
  ( link
  , unlink
  , relay
  , send
  , expect
  , newChan
  , monitor
  , unmonitor
  , match
  , matchIf
  , receiveWait
  )

--------------------------------------------------------------------------------
-- Helpers for static values                                                  --
--------------------------------------------------------------------------------

sdictSendPort_ :: forall a. SerializableDict a -> SerializableDict (SendPort a)
sdictSendPort_ SerializableDict = SerializableDict

returnDict :: forall a. SerializableDict a -> ByteString -> Process a
returnDict SerializableDict = return . decode

sendDict :: forall a. SerializableDict a -> ProcessId -> a -> Process ()
sendDict SerializableDict = send

expectDict :: forall a. SerializableDict a -> Process a
expectDict SerializableDict = expect

newChanDict :: forall a. SerializableDict a -> Process (SendPort a, ReceivePort a)
newChanDict SerializableDict = newChan

cpSplit :: forall a b c d. (a -> Process c) -> (b -> Process d) -> (a, b) -> Process (c, d)
cpSplit f g (a, b) = do
  c <- f a
  d <- g b
  return (c, d)

--------------------------------------------------------------------------------
-- Static dictionaries and associated operations                              --
--------------------------------------------------------------------------------

-- | Serialization dictionary for '()'
sdictUnit :: Closure (SerializableDict ())
sdictUnit = static SerializableDict

-- | Serialization dictionary for 'ProcessId'
sdictProcessId :: Closure (SerializableDict ProcessId)
sdictProcessId = static SerializableDict

-- | Serialization dictionary for 'SendPort'
sdictSendPort :: Typeable a
              => Closure (SerializableDict a) -> Closure (SerializableDict (SendPort a))
sdictSendPort = closureApplyStatic (static sdictSendPort_)

--------------------------------------------------------------------------------
-- Static values                                                              --
--------------------------------------------------------------------------------

sndStatic :: (Typeable a, Typeable b) => StaticPtr ((a, b) -> b)
sndStatic = static snd

--------------------------------------------------------------------------------
-- The CP type and associated combinators                                     --
--------------------------------------------------------------------------------

-- | @CP a b@ is a process with input of type @a@ and output of type @b@
type CP a b = Closure (a -> Process b)

-- | 'CP' version of 'Control.Category.id'
idCP :: Typeable a => CP a a
idCP = static return

-- | 'CP' version of ('Control.Arrow.***')
splitCP :: (Typeable a, Typeable b, Typeable c, Typeable d)
        => CP a c -> CP b d -> CP (a, b) (c, d)
splitCP p q = static cpSplit `closureApplyStatic` p `closureApply` q

-- | 'CP' version of 'Control.Monad.return'
returnCP :: Serializable a
         => Closure (SerializableDict a) -> a -> Closure (Process a)
returnCP dict x =
  closureApplyStatic (static returnDict) dict
    `closureApply` closure (static id) (encode x)

-- | 'CP' version of ('Control.Monad.>>')
seqCP :: (Typeable a, Typeable b)
      => Closure (Process a) -> Closure (Process b) -> Closure (Process b)
seqCP p q = static (>>) `closureApplyStatic` p `closureApply` q

-- | (Not quite the) 'CP' version of ('Control.Monad.>>=')
bindCP :: forall a b. (Typeable a, Typeable b)
       => Closure (Process a) -> CP a b -> Closure (Process b)
bindCP x f = static (>>=) `closureApplyStatic` x `closureApply` f

--------------------------------------------------------------------------------
-- CP versions of Cloud Haskell primitives                                    --
--------------------------------------------------------------------------------

decodeProcessIdStatic :: StaticPtr (ByteString -> ProcessId)
decodeProcessIdStatic = static decode

-- | 'CP' version of 'link'
cpLink :: ProcessId -> Closure (Process ())
cpLink = closure (static (link . decode)) . encode

-- | 'CP' version of 'unlink'
cpUnlink :: ProcessId -> Closure (Process ())
cpUnlink = closure (static (unlink . decode)) . encode

-- | 'CP' version of 'send'
cpSend :: forall a. Typeable a
       => Closure (SerializableDict a) -> ProcessId -> CP a ()
cpSend dict pid =
  closureApplyStatic (static sendDict) dict
    `closureApply` closure decodeProcessIdStatic (encode pid)

-- | 'CP' version of 'expect'
cpExpect :: Typeable a => Closure (SerializableDict a) -> Closure (Process a)
cpExpect = closureApplyStatic (static expectDict)

-- | 'CP' version of 'newChan'
cpNewChan :: Typeable a
          => Closure (SerializableDict a)
          -> Closure (Process (SendPort a, ReceivePort a))
cpNewChan = closureApplyStatic (static newChanDict)

-- | 'CP' version of 'relay'
cpRelay :: ProcessId -> Closure (Process ())
cpRelay = closure (static (relay . decode)) . encode

--------------------------------------------------------------------------------
-- Support for spawn                                                          --
--------------------------------------------------------------------------------

-- | @delay them p@ is a process that waits for a signal (a message of type @()@)
-- from 'them' (origin is not verified) before proceeding as @p@. In order to
-- avoid waiting forever, @delay them p@ monitors 'them'. If it receives a
-- monitor message instead, it proceeds as @p@ too.
delay :: ProcessId -> Process () -> Process ()
delay them p = do
  ref <- monitor them
  let sameRef (ProcessMonitorNotification ref' _ _) = ref == ref'
  receiveWait [
      match           $ \() -> unmonitor ref
    , matchIf sameRef $ \_  -> return ()
    ]
  p

-- | 'CP' version of 'delay'
cpDelayed :: ProcessId -> Closure (Process ()) -> Closure (Process ())
cpDelayed = closureApply . cpDelay'
  where
    cpDelay' :: ProcessId -> Closure (Process () -> Process ())
    cpDelay' = closure (static (delay . decode)) . encode
