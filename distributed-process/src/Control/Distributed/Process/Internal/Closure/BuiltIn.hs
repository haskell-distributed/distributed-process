{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.BuiltIn 
  ( -- * Runtime support for the builtin closures
    remoteTable
    -- * Serialization dictionaries
  , serializableDictUnit
    -- * Closures
  , linkClosure
  , unlinkClosure
  , sendClosure
  , returnClosure
  , expectClosure
  ) where

import Data.Binary (encode)
import Data.Typeable (Typeable, typeOf)
import Control.Distributed.Process.Internal.Primitives (link, unlink)
import Control.Distributed.Process.Internal.Types 
  ( ProcessId
  , Closure
  , Process
  , RemoteTable
  , SerializableDict(..)
  , Closure(..)
  , Static(..)
  , StaticLabel(..)
  )
import Control.Distributed.Process.Internal.Closure.TH (remotable, mkClosure)
import Control.Distributed.Process.Internal.TypeRep () -- Binary instances

serializableDictUnit :: SerializableDict ()
serializableDictUnit = SerializableDict

remotable ['link, 'unlink, 'serializableDictUnit] 

remoteTable :: RemoteTable -> RemoteTable
remoteTable = __remoteTable

--------------------------------------------------------------------------------
-- TH generated closures                                                      --
--------------------------------------------------------------------------------

-- | Closure version of 'link'
linkClosure :: ProcessId -> Closure (Process ())
linkClosure = $(mkClosure 'link)

-- | Closure version of 'unlink'
unlinkClosure :: ProcessId -> Closure (Process ())
unlinkClosure = $(mkClosure 'unlink)

--------------------------------------------------------------------------------
-- Polymorphic closures                                                       --
--                                                                            --
-- TODO: These functions take a SerializableDict as argument. When we get     --
-- proper support for static, ideally this argument disappears completely;    --
-- but if not, it should turn into a static (SerializableDict a). We don't    --
-- require them to be "static" here because we don't have a pure 'unstatic'   --
-- function, and hence have no way of turning a static (SerializableDict a)   --
-- into an actual SerialziableDict a (we need that in order to pattern match  --
-- on the dictionary and bring the type class dictionary into scope, so that  --
-- we can call 'encode' (for instance in 'returnClosure').                    --
--------------------------------------------------------------------------------

-- | Closure version of 'send'
sendClosure :: forall a. SerializableDict a -> ProcessId -> Closure (a -> Process ())
sendClosure SerializableDict pid =
  Closure (Static ClosureSend) (encode (typeOf (undefined :: a), pid)) 

-- | Return any value
returnClosure :: forall a. SerializableDict a -> a -> Closure (Process a)
returnClosure SerializableDict val =
  Closure (Static ClosureReturn) (encode (typeOf (undefined :: a), encode val))

-- | Closure version of 'expect'
expectClosure :: forall a. SerializableDict a -> Closure (Process a)
expectClosure SerializableDict =
  Closure (Static ClosureExpect) (encode (typeOf (undefined :: a)))
