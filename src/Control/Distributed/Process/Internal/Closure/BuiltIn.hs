{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RankNTypes  #-}
module Control.Distributed.Process.Internal.Closure.BuiltIn
  ( -- * Remote table
    remoteTable
    -- * Static dictionaries and associated operations
  , staticDecode
  , sdictUnit
  , sdictProcessId
  , sdictSendPort
  , sdictStatic
  , sdictClosure
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
  , cpEnableTraceRemote
  ) where

import Data.ByteString.Lazy (ByteString)
import Data.Binary (decode, encode)
import Data.Rank1Typeable (Typeable, ANY, ANY1, ANY2, ANY3, ANY4)
import Data.Rank1Dynamic (toDynamic)
import Control.Distributed.Static
  ( RemoteTable
  , registerStatic
  , Static
  , staticLabel
  , staticApply
  , Closure
  , closure
  , closureApplyStatic
  , closureApply
  , staticCompose
  , staticClosure
  )
import Control.Distributed.Process.Serializable
  ( SerializableDict(..)
  , Serializable
  , TypeableDict(..)
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
-- Remote table                                                               --
--------------------------------------------------------------------------------

remoteTable :: RemoteTable -> RemoteTable
remoteTable =
      registerStatic "$decodeDict"      (toDynamic (decodeDict       :: SerializableDict ANY -> ByteString -> ANY))
    . registerStatic "$sdictUnit"       (toDynamic (SerializableDict :: SerializableDict ()))
    . registerStatic "$sdictProcessId"  (toDynamic (SerializableDict :: SerializableDict ProcessId))
    . registerStatic "$sdictSendPort_"  (toDynamic (sdictSendPort_   :: SerializableDict ANY -> SerializableDict (SendPort ANY)))
    . registerStatic "$sdictStatic"     (toDynamic (sdictStatic_     :: TypeableDict ANY -> SerializableDict (Static ANY)))
    . registerStatic "$sdictClosure"    (toDynamic (sdictClosure_    :: TypeableDict ANY -> SerializableDict (Closure ANY)))
    . registerStatic "$returnProcess"   (toDynamic (return           :: ANY -> Process ANY))
    . registerStatic "$seqProcess"      (toDynamic ((>>)             :: Process ANY1 -> Process ANY2 -> Process ANY2))
    . registerStatic "$bindProcess"     (toDynamic ((>>=)            :: Process ANY1 -> (ANY1 -> Process ANY2) -> Process ANY2))
    . registerStatic "$decodeProcessId" (toDynamic (decode           :: ByteString -> ProcessId))
    . registerStatic "$link"            (toDynamic link)
    . registerStatic "$unlink"          (toDynamic unlink)
    . registerStatic "$relay"           (toDynamic relay)
    . registerStatic "$sendDict"        (toDynamic (sendDict         :: SerializableDict ANY -> ProcessId -> ANY -> Process ()))
    . registerStatic "$expectDict"      (toDynamic (expectDict       :: SerializableDict ANY -> Process ANY))
    . registerStatic "$newChanDict"     (toDynamic (newChanDict      :: SerializableDict ANY -> Process (SendPort ANY, ReceivePort ANY)))
    . registerStatic "$cpSplit"         (toDynamic (cpSplit          :: (ANY1 -> Process ANY3) -> (ANY2 -> Process ANY4) -> (ANY1, ANY2) -> Process (ANY3, ANY4)))
    . registerStatic "$snd"             (toDynamic (snd              :: (ANY1, ANY2) -> ANY2))
    . registerStatic "$delay"           (toDynamic delay)
  where
    decodeDict :: forall a. SerializableDict a -> ByteString -> a
    decodeDict SerializableDict = decode

    sdictSendPort_ :: forall a. SerializableDict a -> SerializableDict (SendPort a)
    sdictSendPort_ SerializableDict = SerializableDict

    sdictStatic_ :: forall a. TypeableDict a -> SerializableDict (Static a)
    sdictStatic_ TypeableDict = SerializableDict

    sdictClosure_ :: forall a. TypeableDict a -> SerializableDict (Closure a)
    sdictClosure_ TypeableDict = SerializableDict

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

-- | Static decoder, given a static serialization dictionary.
--
-- See module documentation of "Control.Distributed.Process.Closure" for an
-- example.
staticDecode :: Typeable a => Static (SerializableDict a) -> Static (ByteString -> a)
staticDecode dict = decodeDictStatic `staticApply` dict
  where
    decodeDictStatic :: Typeable a => Static (SerializableDict a -> ByteString -> a)
    decodeDictStatic = staticLabel "$decodeDict"

-- | Serialization dictionary for '()'
sdictUnit :: Static (SerializableDict ())
sdictUnit = staticLabel "$sdictUnit"

-- | Serialization dictionary for 'ProcessId'
sdictProcessId :: Static (SerializableDict ProcessId)
sdictProcessId = staticLabel "$sdictProcessId"

-- | Serialization dictionary for 'SendPort'
sdictSendPort :: Typeable a
              => Static (SerializableDict a) -> Static (SerializableDict (SendPort a))
sdictSendPort = staticApply (staticLabel "$sdictSendPort_")

-- | Serialization dictionary for 'Static'.
sdictStatic :: Typeable a => Static (TypeableDict a) -> Static (SerializableDict (Static a))
sdictStatic = staticApply (staticLabel "$sdictStatic")

-- | Serialization dictionary for 'Closure'.
sdictClosure :: Typeable a => Static (TypeableDict a) -> Static (SerializableDict (Closure a))
sdictClosure = staticApply (staticLabel "$sdictClosure")

--------------------------------------------------------------------------------
-- Static values                                                              --
--------------------------------------------------------------------------------

sndStatic :: Static ((a, b) -> b)
sndStatic = staticLabel "$snd"

--------------------------------------------------------------------------------
-- The CP type and associated combinators                                     --
--------------------------------------------------------------------------------

-- | @CP a b@ is a process with input of type @a@ and output of type @b@
type CP a b = Closure (a -> Process b)

returnProcessStatic :: Typeable a => Static (a -> Process a)
returnProcessStatic = staticLabel "$returnProcess"

-- | 'CP' version of 'Control.Category.id'
idCP :: Typeable a => CP a a
idCP = staticClosure returnProcessStatic

-- | 'CP' version of ('Control.Arrow.***')
splitCP :: (Typeable a, Typeable b, Typeable c, Typeable d)
        => CP a c -> CP b d -> CP (a, b) (c, d)
splitCP p q = cpSplitStatic `closureApplyStatic` p `closureApply` q
  where
    cpSplitStatic :: Static ((a -> Process c) -> (b -> Process d) -> (a, b) -> Process (c, d))
    cpSplitStatic = staticLabel "$cpSplit"

-- | 'CP' version of 'Control.Monad.return'
returnCP :: forall a. Serializable a
         => Static (SerializableDict a) -> a -> Closure (Process a)
returnCP dict x = closure decoder (encode x)
  where
    decoder :: Static (ByteString -> Process a)
    decoder = returnProcessStatic
            `staticCompose`
              staticDecode dict

-- | 'CP' version of ('Control.Monad.>>')
seqCP :: (Typeable a, Typeable b)
      => Closure (Process a) -> Closure (Process b) -> Closure (Process b)
seqCP p q = seqProcessStatic `closureApplyStatic` p `closureApply` q
  where
    seqProcessStatic :: (Typeable a, Typeable b)
                     => Static (Process a -> Process b -> Process b)
    seqProcessStatic = staticLabel "$seqProcess"

-- | (Not quite the) 'CP' version of ('Control.Monad.>>=')
bindCP :: forall a b. (Typeable a, Typeable b)
       => Closure (Process a) -> CP a b -> Closure (Process b)
bindCP x f = bindProcessStatic `closureApplyStatic` x `closureApply` f
  where
    bindProcessStatic :: (Typeable a, Typeable b)
                      => Static (Process a -> (a -> Process b) -> Process b)
    bindProcessStatic = staticLabel "$bindProcess"

--------------------------------------------------------------------------------
-- CP versions of Cloud Haskell primitives                                    --
--------------------------------------------------------------------------------

decodeProcessIdStatic :: Static (ByteString -> ProcessId)
decodeProcessIdStatic = staticLabel "$decodeProcessId"

-- | 'CP' version of 'link'
cpLink :: ProcessId -> Closure (Process ())
cpLink = closure (linkStatic `staticCompose` decodeProcessIdStatic) . encode
  where
    linkStatic :: Static (ProcessId -> Process ())
    linkStatic = staticLabel "$link"

-- | 'CP' version of 'unlink'
cpUnlink :: ProcessId -> Closure (Process ())
cpUnlink = closure (unlinkStatic `staticCompose` decodeProcessIdStatic) . encode
  where
    unlinkStatic :: Static (ProcessId -> Process ())
    unlinkStatic = staticLabel "$unlink"

-- | 'CP' version of 'send'
cpSend :: forall a. Typeable a
       => Static (SerializableDict a) -> ProcessId -> CP a ()
cpSend dict pid = closure decoder (encode pid)
  where
    decoder :: Static (ByteString -> a -> Process ())
    decoder = (sendDictStatic `staticApply` dict)
            `staticCompose`
              decodeProcessIdStatic

    sendDictStatic :: Typeable a
                   => Static (SerializableDict a -> ProcessId -> a -> Process ())
    sendDictStatic = staticLabel "$sendDict"

-- | 'CP' version of 'expect'
cpExpect :: Typeable a => Static (SerializableDict a) -> Closure (Process a)
cpExpect dict = staticClosure (expectDictStatic `staticApply` dict)
  where
    expectDictStatic :: Typeable a => Static (SerializableDict a -> Process a)
    expectDictStatic = staticLabel "$expectDict"

-- | 'CP' version of 'newChan'
cpNewChan :: Typeable a
          => Static (SerializableDict a)
          -> Closure (Process (SendPort a, ReceivePort a))
cpNewChan dict = staticClosure (newChanDictStatic `staticApply` dict)
  where
    newChanDictStatic :: Typeable a
                      => Static (SerializableDict a -> Process (SendPort a, ReceivePort a))
    newChanDictStatic = staticLabel "$newChanDict"

-- | 'CP' version of 'relay'
cpRelay :: ProcessId -> Closure (Process ())
cpRelay = closure (relayStatic `staticCompose` decodeProcessIdStatic) . encode
  where
    relayStatic :: Static (ProcessId -> Process ())
    relayStatic = staticLabel "$relay"

-- TODO: move cpEnableTraceRemote into Trace/Primitives.hs

cpEnableTraceRemote :: ProcessId -> Closure (Process ())
cpEnableTraceRemote =
    closure (enableTraceStatic `staticCompose` decodeProcessIdStatic) . encode
  where
    enableTraceStatic :: Static (ProcessId -> Process ())
    enableTraceStatic = staticLabel "$enableTraceRemote"

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
    cpDelay' pid = closure decoder (encode pid)

    decoder :: Static (ByteString -> Process () -> Process ())
    decoder = delayStatic `staticCompose` decodeProcessIdStatic

    delayStatic :: Static (ProcessId -> Process () -> Process ())
    delayStatic = staticLabel "$delay"
