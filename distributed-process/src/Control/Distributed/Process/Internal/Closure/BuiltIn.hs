module Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( -- * Remote table 
    remoteTable
    -- * Static dictionaries and associated operations
  , staticDecode
  , sdictUnit
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
  , cpLink
  , cpUnlink
  , cpSend
  , cpExpect
  , cpNewChan
  ) where

import Prelude hiding (snd)
import qualified Prelude (snd)
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
  , Closure(Closure)
  , closureApplyStatic
  , closureApply
  , staticCompose
  , staticClosure
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
  )
import Control.Distributed.Process.Internal.Primitives 
  ( link
  , unlink
  , send
  , expect
  , newChan
  )

--------------------------------------------------------------------------------
-- Remote table                                                               --
--------------------------------------------------------------------------------

remoteTable :: RemoteTable -> RemoteTable
remoteTable = 
      registerStatic "$decodeDict"      (toDynamic decodeDict) 
    . registerStatic "$sdictUnit"       (toDynamic dictUnit)
    . registerStatic "$sdictProcessId"  (toDynamic dictProcessId) 
    . registerStatic "$sdictSendPort_"  (toDynamic sdictSendPort_)
    . registerStatic "$returnProcess"   (toDynamic returnProcess)
    . registerStatic "$seqProcess"      (toDynamic seqProcess)
    . registerStatic "$bindProcess"     (toDynamic bindProcess)
    . registerStatic "$decodeProcessId" (toDynamic decodeProcessId)
    . registerStatic "$link"            (toDynamic link)
    . registerStatic "$unlink"          (toDynamic unlink)
    . registerStatic "$sendDict"        (toDynamic sendDict)
    . registerStatic "$expectDict"      (toDynamic expectDict)
    . registerStatic "$newChanDict"     (toDynamic newChanDict)
    . registerStatic "$cpSplit"         (toDynamic cpSplit)
    . registerStatic "$snd"             (toDynamic snd)
  where
    decodeDict :: SerializableDict ANY -> ByteString -> ANY
    decodeDict SerializableDict = decode

    dictUnit :: SerializableDict ()
    dictUnit = SerializableDict

    dictProcessId :: SerializableDict ProcessId
    dictProcessId = SerializableDict

    sdictSendPort_ :: SerializableDict ANY -> SerializableDict (SendPort ANY)
    sdictSendPort_ SerializableDict = SerializableDict

    returnProcess :: ANY -> Process ANY
    returnProcess = return

    seqProcess :: Process ANY1 -> Process ANY2 -> Process ANY2
    seqProcess = (>>)

    bindProcess :: Process ANY1 -> (ANY1 -> Process ANY2) -> Process ANY2
    bindProcess = (>>=)

    decodeProcessId :: ByteString -> ProcessId
    decodeProcessId = decode

    sendDict :: SerializableDict ANY -> ProcessId -> ANY -> Process ()
    sendDict SerializableDict = send

    expectDict :: SerializableDict ANY -> Process ANY
    expectDict SerializableDict = expect

    newChanDict :: SerializableDict ANY -> Process (SendPort ANY, ReceivePort ANY)
    newChanDict SerializableDict = newChan

    cpSplit :: (ANY1 -> Process ANY3) -> (ANY2 -> Process ANY4) -> (ANY1, ANY2) -> Process (ANY3, ANY4)
    cpSplit f g (a, b) = f a >>= \c -> g b >>= \d -> return (c, d)

    snd :: (ANY1, ANY2) -> ANY2
    snd = Prelude.snd

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

idCP :: Typeable a => CP a a
idCP = staticClosure returnProcessStatic

splitCP :: (Typeable a, Typeable b, Typeable c, Typeable d) 
        => CP a c -> CP b d -> CP (a, b) (c, d)
splitCP = undefined

returnCP :: forall a. Serializable a 
         => Static (SerializableDict a) -> a -> Closure (Process a)
returnCP dict x = Closure decoder (encode x)
  where
    decoder :: Static (ByteString -> Process a)
    decoder = returnProcessStatic
            `staticCompose`
              staticDecode dict

seqCP :: (Typeable a, Typeable b)
      => Closure (Process a) -> Closure (Process b) -> Closure (Process b)
seqCP p q = seqProcessStatic `closureApplyStatic` p `closureApply` q 
  where
    seqProcessStatic :: (Typeable a, Typeable b)
                     => Static (Process a -> Process b -> Process b)
    seqProcessStatic = staticLabel "$seqProcess"

bindCP :: forall a b. (Typeable a, Typeable b)
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
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

-- | Closure version of 'link'
cpLink :: ProcessId -> Closure (Process ())
cpLink = Closure (linkStatic `staticCompose` decodeProcessIdStatic) . encode 
  where
    linkStatic :: Static (ProcessId -> Process ())
    linkStatic = staticLabel "$link"

-- | Closure version of 'unlink'
cpUnlink :: ProcessId -> Closure (Process ())
cpUnlink = Closure (unlinkStatic `staticCompose` decodeProcessIdStatic) . encode
  where
    unlinkStatic :: Static (ProcessId -> Process ())
    unlinkStatic = staticLabel "$unlink"

-- | Closure version of 'send'
cpSend :: forall a. Typeable a 
       => Static (SerializableDict a) -> ProcessId -> Closure (a -> Process ())
cpSend dict pid = Closure decoder (encode pid)
  where
    decoder :: Static (ByteString -> a -> Process ())
    decoder = (sendDictStatic `staticApply` dict)
            `staticCompose` 
              decodeProcessIdStatic 

    sendDictStatic :: Typeable a 
                   => Static (SerializableDict a -> ProcessId -> a -> Process ())
    sendDictStatic = staticLabel "$sendDict" 

-- | Closure version of 'expect'
cpExpect :: Typeable a => Static (SerializableDict a) -> Closure (Process a)
cpExpect dict = staticClosure (expectDictStatic `staticApply` dict)
  where
    expectDictStatic :: Typeable a => Static (SerializableDict a -> Process a)
    expectDictStatic = staticLabel "$expectDict"

-- | Closure version of 'newChan'
cpNewChan :: Typeable a 
          => Static (SerializableDict a) 
          -> Closure (Process (SendPort a, ReceivePort a))
cpNewChan dict = staticClosure (newChanDictStatic `staticApply` dict)
  where
    newChanDictStatic :: Typeable a 
                      => Static (SerializableDict a -> Process (SendPort a, ReceivePort a))
    newChanDictStatic = staticLabel "$newChanDict"                  
