-- | Reimplementation of Dynamic that supports dynBind
--
-- We don't have access to the internal representation of Dynamic, otherwise
-- we would not have to redefine it completely. Note that we use this only
-- internally, so the incompatibility with "our" Dynamic from the standard 
-- Dynamic is not important.
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic(..)
  , toDyn
  , fromDyn
  , fromDynamic
  , dynTypeRep
  , dynApply
  , dynApp
  , GHC.unsafeCoerce#
  ) where

import Data.Typeable (Typeable, TypeRep, typeOf, funResultTy)
import qualified GHC.Prim as GHC (Any, unsafeCoerce#)
import Data.Maybe (fromMaybe)

data Dynamic = Dynamic TypeRep GHC.Any

toDyn :: Typeable a => a -> Dynamic
toDyn x = Dynamic (typeOf x) (GHC.unsafeCoerce# x)

fromDyn :: Typeable a => Dynamic -> a -> a
fromDyn (Dynamic rep val) a =
  if rep == typeOf a 
    then GHC.unsafeCoerce# val
    else a

fromDynamic :: forall a. Typeable a => Dynamic -> Maybe a
fromDynamic (Dynamic rep val) = 
  if rep == typeOf (undefined :: a)
    then Just (GHC.unsafeCoerce# val)
    else Nothing

dynTypeRep :: Dynamic -> TypeRep
dynTypeRep (Dynamic t _) = t

instance Show Dynamic where
  show = show . dynTypeRep

dynApply :: Dynamic -> Dynamic -> Maybe Dynamic
dynApply (Dynamic t1 f) (Dynamic t2 x) =
  case funResultTy t1 t2 of
    Just t3 -> Just (Dynamic t3 (GHC.unsafeCoerce# f x))
    Nothing -> Nothing

dynApp :: Dynamic -> Dynamic -> Dynamic
dynApp f x = fromMaybe (error typeError) (dynApply f x)
  where
    typeError  = "Type error in dynamic application.\n" 
              ++ "Can't apply function " ++ show f
              ++ " to argument " ++ show x
