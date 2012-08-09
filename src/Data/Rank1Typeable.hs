module Data.Rank1Typeable 
  ( Rank1TypeRep 
  , underlyingTypeRep
  , typeOf
    -- * Type variables
  , ANY
  , ANY1
  , ANY2
  , ANY3
  , ANY4
  , ANY5
  , ANY6
  , ANY7
  , ANY8
  , ANY9
    -- * Internal functions
  , occurs
  , subst
  , unify
  ) where

import Data.Typeable (Typeable, TypeRep, TyCon)
import Control.Arrow ((***))
import qualified Data.Typeable as Typeable (typeOf, splitTyConApp, mkTyConApp)

newtype Rank1TypeRep = Rank1TypeRep { underlyingTypeRep :: TypeRep }
  deriving Eq

instance Show Rank1TypeRep where
  show = show . underlyingTypeRep

typeOf :: Typeable a => a -> Rank1TypeRep
typeOf = Rank1TypeRep . Typeable.typeOf

data ANY  deriving Typeable
data ANY1 deriving Typeable
data ANY2 deriving Typeable
data ANY3 deriving Typeable
data ANY4 deriving Typeable
data ANY5 deriving Typeable
data ANY6 deriving Typeable
data ANY7 deriving Typeable
data ANY8 deriving Typeable
data ANY9 deriving Typeable

tvars :: [Rank1TypeRep]
tvars = 
  [ typeOf (undefined :: ANY) 
  , typeOf (undefined :: ANY1) 
  , typeOf (undefined :: ANY2) 
  , typeOf (undefined :: ANY3) 
  , typeOf (undefined :: ANY4) 
  , typeOf (undefined :: ANY5) 
  , typeOf (undefined :: ANY6) 
  , typeOf (undefined :: ANY7) 
  , typeOf (undefined :: ANY8) 
  , typeOf (undefined :: ANY9) 
  ]

isTVar :: Rank1TypeRep -> Bool
isTVar = flip elem tvars

splitTyConApp :: Rank1TypeRep -> (TyCon, [Rank1TypeRep])
splitTyConApp t = 
  let (c, ts) = Typeable.splitTyConApp (underlyingTypeRep t)
  in (c, map Rank1TypeRep ts)

mkTyConApp :: TyCon -> [Rank1TypeRep] -> Rank1TypeRep
mkTyConApp c ts 
  = Rank1TypeRep (Typeable.mkTyConApp c (map underlyingTypeRep ts))

occurs :: Rank1TypeRep -> Rank1TypeRep -> Bool
occurs x t 
  | x == t    = True
  | otherwise = let (_, ts) = splitTyConApp t
                in any (occurs x) ts

subst :: Rank1TypeRep -> Rank1TypeRep -> Rank1TypeRep -> Rank1TypeRep
subst x t t' 
  | x == t'   = t
  | otherwise = let (c, ts) = splitTyConApp t'
                in mkTyConApp c (map (subst x t) ts) 

unify :: Monad m => Rank1TypeRep -> Rank1TypeRep -> m [(Rank1TypeRep, Rank1TypeRep)]
unify t1 t2 = unify' [(t1, t2)]

unify' :: Monad m 
      => [(Rank1TypeRep, Rank1TypeRep)] 
      -> m [(Rank1TypeRep, Rank1TypeRep)]
unify' [] = 
  return []
unify' ((x, t) : eqs) | isTVar x && not (isTVar t) =
  if x `occurs` t 
    then fail "Occurs check"
    else do
      s <- unify' (map (subst x t *** subst x t) eqs)
      return ((x, t) : s)
unify' ((t, x) : eqs) | isTVar x && not (isTVar t) =
  unify' ((x, t) : eqs)
unify' ((x, x') : eqs) | isTVar x && isTVar x' && x == x' =
  unify' eqs
unify' ((t1, t2) : eqs) = do
  let (c1, ts1) = splitTyConApp t1 
      (c2, ts2) = splitTyConApp t2 
  if c1 /= c2 
    then fail $ "Cannot unify' " ++ show c1 ++ " and " ++ show c2
    else unify' (zip ts1 ts2 ++ eqs)
