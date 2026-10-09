-- | Template Haskell support
{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.TH
  ( -- * User-level API
    functionSDict
  , functionTDict
  , mkClosure
    -- * Used by the generated code
  , argOf
  , argDict
  , resultDict
  ) where

import Language.Haskell.TH (Q, Exp, Name, varE, staticE)
import Data.Binary (decode, encode)
import Control.Distributed.Static (closure)
import Control.Distributed.Process.Internal.Types (Process)
import Control.Distributed.Process.Serializable
  ( Serializable
  , SerializableDict(SerializableDict)
  )

-- | If @f : T1 -> T2@ is a monomorphic function
-- then @$(functionSDict 'f) :: Closure (SerializableDict T1)@.
functionSDict :: Name -> Q Exp
functionSDict n = staticE [| argDict $(varE n) |]

-- | If @f : T1 -> Process T2@ is a monomorphic function
-- then @$(functionTDict 'f) :: Closure (SerializableDict T2)@.
functionTDict :: Name -> Q Exp
functionTDict n = staticE [| resultDict $(varE n) |]

-- | If @f : T1 -> T2@ then @$(mkClosure 'f) :: T1 -> Closure T2@.
--
-- The argument type is pinned down by 'argOf' so that the generated code is not
-- overloaded: otherwise GHC specializes it, which duplicates the @static@ form.
mkClosure :: Name -> Q Exp
mkClosure n =
  [| \x -> closure $(staticE [| $(varE n) . decode |]) (encode (argOf $(varE n) x)) |]

argOf :: (a -> b) -> a -> a
argOf _ x = x

argDict :: Serializable a => (a -> b) -> SerializableDict a
argDict _ = SerializableDict

resultDict :: Serializable b => (a -> Process b) -> SerializableDict b
resultDict _ = SerializableDict
