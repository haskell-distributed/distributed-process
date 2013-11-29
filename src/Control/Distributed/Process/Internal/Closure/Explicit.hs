{-# LANGUAGE ScopedTypeVariables
  , MultiParamTypeClasses
  , FlexibleInstances
  , FunctionalDependencies
  , FlexibleContexts
  , UndecidableInstances
  , KindSignatures
  , GADTs
  , OverlappingInstances
  , EmptyDataDecls
  , DeriveDataTypeable #-}
module Control.Distributed.Process.Internal.Closure.Explicit
  (
    RemoteRegister
  , MkTDict(..)
  , mkStaticVal
  , mkClosureValSingle
  , mkClosureVal
  , call'
  ) where

import Control.Distributed.Static
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Internal.Closure.BuiltIn
  ( -- Static dictionaries and associated operations
    staticDecode
  )
import Control.Distributed.Process
import Data.Rank1Dynamic
import Data.Rank1Typeable
import Data.Binary(encode,put,get,Binary)
import qualified Data.ByteString.Lazy as B

-- | A RemoteRegister is a trasformer on a RemoteTable to register additional static values.
type RemoteRegister = RemoteTable -> RemoteTable

-- | This takes an explicit name and a value, and produces both a static reference to the name and a RemoteRegister for it.
mkStaticVal :: Serializable a => String -> a -> (Static a, RemoteRegister)
mkStaticVal n v = (staticLabel n_s, registerStatic n_s (toDynamic v))
    where n_s = n

class MkTDict a where
    mkTDict :: String -> a -> RemoteRegister

instance (Serializable b) => MkTDict (Process b) where
    mkTDict _ _ = registerStatic (show (typeOf (undefined :: b)) ++ "__staticDict") (toDynamic (SerializableDict :: SerializableDict b))

instance MkTDict a where
    mkTDict _ _ = id

-- | This takes an explicit name, a function of arity one, and creates a creates a function yielding a closure and a remote register for it.
mkClosureValSingle :: forall a b. (Serializable a, Typeable b, MkTDict b) => String -> (a -> b) -> (a -> Closure b, RemoteRegister)
mkClosureValSingle n v = (c, registerStatic n_s (toDynamic v) .
                             registerStatic n_sdict (toDynamic sdict) .
                             mkTDict n_tdict (undefined :: b)
                         ) where
    n_s = n
    n_sdict = n ++ "__sdict"
    n_tdict = n ++ "__tdict"

    c = closure decoder . encode

    decoder = (staticLabel n_s :: Static (a -> b)) `staticCompose` staticDecode (staticLabel n_sdict :: Static (SerializableDict a))

    sdict :: (SerializableDict a)
    sdict = SerializableDict

-- | This takes an explict name, a function of any arity, and creates a function yielding a closure and a remote register for it.
mkClosureVal :: forall func argTuple result closureFunction.
                (Curry (argTuple -> Closure result) closureFunction,
                 MkTDict result,
                 Uncurry HTrue argTuple func result,
                 Typeable result, Serializable argTuple, IsFunction func HTrue) =>
                String -> func -> (closureFunction, RemoteRegister)
mkClosureVal n v = (curryFun c, rtable)
    where
      uv :: argTuple -> result
      uv = uncurry' reify v

      n_s = n
      n_sdict = n ++ "__sdict"
      n_tdict = n ++ "__tdict"

      c :: argTuple -> Closure result
      c = closure decoder . encode

      decoder :: Static (B.ByteString -> result)
      decoder = (staticLabel n_s :: Static (argTuple -> result)) `staticCompose` staticDecode (staticLabel n_sdict :: Static (SerializableDict argTuple))

      rtable = registerStatic n_s (toDynamic uv) .
               registerStatic n_sdict (toDynamic sdict) .
               mkTDict n_tdict (undefined :: result)


      sdict :: (SerializableDict argTuple)
      sdict = SerializableDict

-- | Works just like standard call, but with a simpler signature.
call' :: forall a. Serializable a => NodeId -> Closure (Process a) -> Process a
call' = call (staticLabel $ (show $ typeOf $ (undefined :: a)) ++ "__staticDict")


data EndOfTuple deriving Typeable
instance Binary EndOfTuple where
    put _ = return ()
    get = return undefined

-- This generic curry is straightforward
class Curry a b | a -> b where
    curryFun :: a -> b

instance Curry ((a,EndOfTuple) -> b) (a -> b) where
    curryFun f = \x -> f (x,undefined)

instance Curry (b -> c) r => Curry ((a,b) -> c) (a -> r) where
    curryFun f = \x -> curryFun (\y -> (f (x,y)))


-- This generic uncurry courtesy Andrea Vezzosi
data HTrue
data HFalse
data Fun :: * -> * -> * -> * where
  Done :: Fun EndOfTuple r r
  Moar :: Fun xs f r -> Fun (x,xs) (x -> f) r

class Uncurry'' args func result | func -> args, func -> result, args result -> func where
    reify :: Fun args func result

class Uncurry flag args func result | flag func -> args, flag func -> result, args result -> func where
    reify' :: flag -> Fun args func result

instance Uncurry'' rest f r => Uncurry HTrue (a,rest) (a -> f) r where
    reify' _ = Moar reify

instance Uncurry HFalse EndOfTuple a a where
    reify' _ = Done

instance (IsFunction func b, Uncurry b args func result) => Uncurry'' args func result where
    reify = reify' (undefined :: b)

uncurry' :: Fun args func result -> func -> args -> result
uncurry' Done r _ = r
uncurry' (Moar fun) f (x,xs) = uncurry' fun (f x) xs

class IsFunction t b | t -> b
instance (b ~ HTrue) => IsFunction (a -> c) b
instance (b ~ HFalse) => IsFunction a b

