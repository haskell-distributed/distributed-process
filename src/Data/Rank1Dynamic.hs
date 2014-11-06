-- | Dynamic values with support for rank-1 polymorphic types.
--
-- [Examples of fromDynamic]
--
-- These examples correspond to the 'Data.Rank1Typeable.isInstanceOf' examples
-- in "Data.Rank1Typeable".
--
-- > > do f <- fromDynamic (toDynamic (even :: Int -> Bool)) ; return $ (f :: Int -> Int) 0
-- > Left "Cannot unify Int and Bool"
-- >
-- > > do f <- fromDynamic (toDynamic (const 1 :: ANY -> Int)) ; return $ (f :: Int -> Int) 0
-- > Right 1
-- >
-- > > do f <- fromDynamic (toDynamic (unsafeCoerce :: ANY1 -> ANY2)) ; return $ (f :: Int -> Int) 0
-- > Right 0
-- >
-- > > do f <- fromDynamic (toDynamic (id :: ANY -> ANY)) ; return $ (f :: Int -> Bool) 0
-- > Left "Cannot unify Bool and Int"
-- >
-- > > do f <- fromDynamic (toDynamic (undefined :: ANY)) ; return $ (f :: Int -> Int) 0
-- > Right *** Exception: Prelude.undefined
-- >
-- > > do f <- fromDynamic (toDynamic (id :: ANY -> ANY)) ; return $ (f :: Int)
-- > Left "Cannot unify Int and ->"
-- >
-- > > do f <- fromDynamic (toDynamic (reifyConstraints return :: Dict (Monad Maybe) -> Int -> Maybe Int))
-- >      return $ (abstractConstraints (f :: Dict (Monad Maybe) -> Int -> Maybe Int)) 0
-- > Right (Just 0)
--
-- Please, see @tests/test.hs@ for examples of how to write the higher-kinded
-- case in ghc versions earlier than 7.6.3.
--
-- [Examples of dynApply]
--
-- These examples correspond to the 'Data.Rank1Typeable.funResultTy' examples
-- in "Data.Rank1Typeable".
--
-- > > do app <- toDynamic (id :: ANY -> ANY) `dynApply` toDynamic True ; f <- fromDynamic app ; return $ (f :: Bool)
-- > Right True
-- >
-- > > do app <- toDynamic (const :: ANY -> ANY1 -> ANY) `dynApply` toDynamic True ; f <- fromDynamic app ; return $ (f :: Int -> Bool) 0
-- > Right True
-- >
-- > > do app <- toDynamic (($ True) :: (Bool -> ANY) -> ANY) `dynApply` toDynamic (id :: ANY -> ANY) ; f <- fromDynamic app ; return (f :: Bool)
-- > Right True
-- >
-- > > app <- toDynamic (const :: ANY -> ANY1 -> ANY) `dynApply` toDynamic (id :: ANY -> ANY) ; f <- fromDynamic app ; return $ (f :: Int -> Bool -> Bool) 0 True
-- > Right True
-- >
-- > > do app <- toDynamic ((\f -> f . f) :: (ANY -> ANY) -> ANY -> ANY) `dynApply` toDynamic (even :: Int -> Bool) ; f <- fromDynamic app ; return (f :: ())
-- > Left "Cannot unify Int and Bool"
--
-- [Using toDynamic]
--
-- When using polymorphic values you need to give an explicit type annotation:
--
-- > > toDynamic id
-- >
-- > <interactive>:46:1:
-- >     Ambiguous type variable `a0' in the constraint:
-- >       (Typeable a0) arising from a use of `toDynamic'
-- >     Probable fix: add a type signature that fixes these type variable(s)
-- >     In the expression: toDynamic id
-- >     In an equation for `it': it = toDynamic id
--
-- versus
--
-- > > toDynamic (id :: ANY -> ANY)
-- > <<ANY -> ANY>>
--
-- Note that these type annotation are checked by ghc like any other:
--
-- > > toDynamic (id :: ANY -> ANY1)
-- >
-- > <interactive>:45:12:
-- >     Couldn't match expected type `V1' with actual type `V0'
-- >     Expected type: ANY -> ANY1
-- >       Actual type: ANY -> ANY
-- >     In the first argument of `toDynamic', namely `(id :: ANY -> ANY1)'
-- >     In the expression: toDynamic (id :: ANY -> ANY1)
module Data.Rank1Dynamic
  ( Dynamic
  , toDynamic
  , fromDynamic
  , TypeError
  , dynTypeRep
  , dynApply
  ) where

import qualified GHC.Prim as GHC (Any)
import Data.Rank1Typeable
  ( Typeable
  , TypeRep
  , typeOf
  , isInstanceOf
  , TypeError
  , funResultTy
  )
import Unsafe.Coerce (unsafeCoerce)

-- | Encapsulate an object and its type
data Dynamic = Dynamic TypeRep GHC.Any

instance Show Dynamic where
  showsPrec _ (Dynamic t _) = showString "<<" . shows t . showString ">>"

-- | Introduce a dynamic value
toDynamic :: Typeable a => a -> Dynamic
toDynamic x = Dynamic (typeOf x) (unsafeCoerce x)

-- | Eliminate a dynamic value
fromDynamic :: Typeable a => Dynamic -> Either TypeError a
fromDynamic (Dynamic t v) =
  case unsafeCoerce v of
    r -> case typeOf r `isInstanceOf` t of
      Left err -> Left err
      Right () -> Right r

-- | Apply one dynamic value to another
dynApply :: Dynamic -> Dynamic -> Either TypeError Dynamic
dynApply (Dynamic t1 f) (Dynamic t2 x) = do
  t3 <- funResultTy t1 t2
  return $ Dynamic t3 (unsafeCoerce f x)

-- | The type representation of a dynamic value
dynTypeRep :: Dynamic -> TypeRep
dynTypeRep (Dynamic t _) = t
