-- | Reimplementation of Dynamic that supports dynBind
--
-- We don't have access to the internal representation of Dynamic, otherwise
-- we would not have to redefine it completely. Note that we use this only
-- internally, so the incompatibility with "our" Dynamic from the standard 
-- Dynamic is not important.
{-# LANGUAGE MagicHash #-}
module Control.Distributed.Process.Internal.Dynamic 
  ( Dynamic
  , toDyn
  , fromDyn
  , fromDynamic
  , dynBindIO
  , dynBindIO'
  ) where

import Data.Typeable 
  ( Typeable
  , TypeRep
  , typeOf
  , TyCon
  , typeRepTyCon
  , splitTyConApp
  , funResultTy
  )
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

tyConIO :: TyCon 
tyConIO = typeRepTyCon (typeOf (undefined :: IO ()))

bindIO :: IO a -> (a -> IO b) -> IO b
bindIO = (>>=)

dynBindIO :: Dynamic -> Dynamic -> Maybe Dynamic
-- IO a -> (a -> IO b) -> IO b
dynBindIO (Dynamic t1 x) (Dynamic t2 f) = 
  case splitTyConApp t1 of
    (io, [a]) | io == tyConIO ->
      case funResultTy t2 a of
        Just ioB -> Just (Dynamic ioB (GHC.unsafeCoerce# bindIO x f))
        _  -> Nothing
    _ -> Nothing 
  
dynBindIO' :: Dynamic -> Dynamic -> Dynamic
dynBindIO' x f = fromMaybe (error typeError) (dynBindIO x f)
  where
    typeError  = "Type error in dynamic bind.\n"
              ++ "Can't bind " ++ show x ++ " to " ++ show f
