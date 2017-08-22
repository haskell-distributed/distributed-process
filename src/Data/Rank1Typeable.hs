-- | Runtime type representation of terms with support for rank-1 polymorphic
-- types with type variables of kind *.
--
-- The essence of this module is that we use the standard 'Typeable'
-- representation of "Data.Typeable" but we introduce a special (empty) data
-- type 'TypVar' which represents type variables. 'TypVar' is indexed by an
-- arbitrary other data type, giving you an unbounded number of type variables;
-- for convenience, we define 'ANY', 'ANY1', .., 'ANY9'.
--
-- [Examples of isInstanceOf]
--
-- > -- We CANNOT use a term of type 'Int -> Bool' as 'Int -> Int'
-- > > typeOf (undefined :: Int -> Int) `isInstanceOf` typeOf (undefined :: Int -> Bool)
-- > Left "Cannot unify Int and Bool"
-- >
-- > -- We CAN use a term of type 'forall a. a -> Int' as 'Int -> Int'
-- > > typeOf (undefined :: Int -> Int) `isInstanceOf` typeOf (undefined :: ANY -> Int)
-- > Right ()
-- >
-- > -- We CAN use a term of type 'forall a b. a -> b' as 'forall a. a -> a'
-- > > typeOf (undefined :: ANY -> ANY) `isInstanceOf` typeOf (undefined :: ANY -> ANY1)
-- > Right ()
-- >
-- > -- We CANNOT use a term of type 'forall a. a -> a' as 'forall a b. a -> b'
-- > > typeOf (undefined :: ANY -> ANY1) `isInstanceOf` typeOf (undefined :: ANY -> ANY)
-- > Left "Cannot unify Succ and Zero"
-- >
-- > -- We CAN use a term of type 'forall a. a' as 'forall a. a -> a'
-- > > typeOf (undefined :: ANY -> ANY) `isInstanceOf` typeOf (undefined :: ANY)
-- > Right ()
-- >
-- > -- We CANNOT use a term of type 'forall a. a -> a' as 'forall a. a'
-- > > typeOf (undefined :: ANY) `isInstanceOf` typeOf (undefined :: ANY -> ANY)
-- > Left "Cannot unify Skolem and ->"
--
-- (Admittedly, the quality of the type errors could be improved.)
--
-- [Examples of funResultTy]
--
-- > -- Apply fn of type (forall a. a -> a) to arg of type Bool gives Bool
-- > > funResultTy (typeOf (undefined :: ANY -> ANY)) (typeOf (undefined :: Bool))
-- > Right Bool
-- >
-- > -- Apply fn of type (forall a b. a -> b -> a) to arg of type Bool gives forall a. a -> Bool
-- > > funResultTy (typeOf (undefined :: ANY -> ANY1 -> ANY)) (typeOf (undefined :: Bool))
-- > Right (ANY -> Bool) -- forall a. a -> Bool
-- >
-- > -- Apply fn of type (forall a. (Bool -> a) -> a) to argument of type (forall a. a -> a) gives Bool
-- > > funResultTy (typeOf (undefined :: (Bool -> ANY) -> ANY)) (typeOf (undefined :: ANY -> ANY))
-- > Right Bool
-- >
-- > -- Apply fn of type (forall a b. a -> b -> a) to arg of type (forall a. a -> a) gives (forall a b. a -> b -> b)
-- > > funResultTy (typeOf (undefined :: ANY -> ANY1 -> ANY)) (typeOf (undefined :: ANY1 -> ANY1))
-- > Right (ANY -> ANY1 -> ANY1)
-- >
-- > -- Cannot apply function of type (forall a. (a -> a) -> a -> a) to arg of type (Int -> Bool)
-- > > funResultTy (typeOf (undefined :: (ANY -> ANY) -> (ANY -> ANY))) (typeOf (undefined :: Int -> Bool))
-- > Left "Cannot unify Int and Bool"
{-# LANGUAGE BangPatterns #-}
module Data.Rank1Typeable
  ( -- * Basic types
    TypeRep
  , typeOf
  , splitTyConApp
  , mkTyConApp
    -- * Operations on type representations
  , isInstanceOf
  , funResultTy
  , TypeError
    -- * Type variables
  , TypVar
  , Zero
  , Succ
  , V0
  , V1
  , V2
  , V3
  , V4
  , V5
  , V6
  , V7
  , V8
  , V9
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
    -- * Re-exports from Typeable
  , Typeable
  ) where

import Prelude hiding (succ)
import Control.Arrow ((***), second)
import Control.Monad (void)
import Control.Applicative ((<$>))
import Data.Binary
import Data.Function (on)
import Data.List (intersperse, isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Typeable ( Typeable )
import qualified Data.Typeable as T
import GHC.Fingerprint

tcList, tcFun :: TyCon
tcList = fst $ splitTyConApp $ typeOf [()]
tcFun = fst $ splitTyConApp $ typeOf (\() -> ())

--------------------------------------------------------------------------------
-- The basic type                                                             --
--------------------------------------------------------------------------------

-- | Dynamic type representation with support for rank-1 types
data TypeRep
    = TRCon TyCon
    | TRApp {-# UNPACK #-} !Fingerprint TypeRep TypeRep

data TyCon = TyCon
    { tyConFingerprint :: {-# UNPACK #-} !Fingerprint
    , tyConPackage :: String
    , tyConModule :: String
    , tyConName :: String
    }

-- | The fingerprint of a TypeRep
typeRepFingerprint :: TypeRep -> Fingerprint
typeRepFingerprint (TRCon c) = tyConFingerprint c
typeRepFingerprint (TRApp fp _ _) = fp

-- | Compare two type representations
instance Eq TyCon where
  (==) = (==) `on` tyConFingerprint

instance Eq TypeRep where
  (==) = (==) `on` typeRepFingerprint

--- Binary instance for 'TypeRep', avoiding orphan instances
instance Binary TypeRep where
  put (splitTyConApp -> (tc, ts)) = do
    put $ tyConPackage tc
    put $ tyConModule tc
    put $ tyConName tc
    put ts
  get = do
    package <- get
    modul   <- get
    name    <- get
    ts      <- get
    return $ mkTyConApp (mkTyCon3 package modul name) ts

-- | The type representation of any 'Typeable' term
typeOf :: Typeable a => a -> TypeRep
typeOf = trTypeOf . T.typeOf

-- | Conversion from Data.Typeable.TypeRep to Data.Rank1Typeable.TypeRep
trTypeOf :: T.TypeRep -> TypeRep
trTypeOf t = let (c, ts) = T.splitTyConApp t
              in foldl mkTRApp (TRCon $ fromTypeableTyCon c) $ map trTypeOf ts
  where
    fromTypeableTyCon c =
      TyCon (T.tyConFingerprint c)
            (T.tyConPackage c)
            (T.tyConModule c)
            (T.tyConName c)

-- | Applies a TypeRep to another.
mkTRApp :: TypeRep -> TypeRep -> TypeRep
mkTRApp t0 t1 = TRApp fp t0 t1
  where
    fp = fingerprintFingerprints [typeRepFingerprint t0, typeRepFingerprint t1]

mkTyCon3 :: String -> String -> String -> TyCon
mkTyCon3 pkg m name = TyCon fp pkg m name
  where
    fp = fingerprintFingerprints [ fingerprintString s | s <- [pkg, m, name] ]

--------------------------------------------------------------------------------
-- Constructors/destructors (views)                                           --
--------------------------------------------------------------------------------

-- | Split a type representation into the application of
-- a type constructor and its argument
splitTyConApp :: TypeRep -> (TyCon, [TypeRep])
splitTyConApp = go []
  where
    go xs (TRCon c) = (c, xs)
    go xs (TRApp _ t0 t1) = go (t1 : xs) t0

-- | Inverse of 'splitTyConApp'
mkTyConApp :: TyCon -> [TypeRep] -> TypeRep
mkTyConApp c = foldl mkTRApp (TRCon c)

isTypVar :: TypeRep -> Maybe Var
isTypVar (splitTyConApp -> (c, [t])) | c == typVar = Just t
isTypVar _ = Nothing

mkTypVar :: Var -> TypeRep
mkTypVar x = mkTyConApp typVar [x]

typVar :: TyCon
typVar = let (c, _) = splitTyConApp (typeOf (undefined :: TypVar V0)) in c

skolem :: TyCon
skolem = let (c, _) = splitTyConApp (typeOf (undefined :: Skolem V0)) in c

--------------------------------------------------------------------------------
-- Type variables                                                             --
--------------------------------------------------------------------------------

data TypVar a deriving Typeable
data Skolem a deriving Typeable
data Zero     deriving Typeable
data Succ a   deriving Typeable

type V0 = Zero
type V1 = Succ V0
type V2 = Succ V1
type V3 = Succ V2
type V4 = Succ V3
type V5 = Succ V4
type V6 = Succ V5
type V7 = Succ V6
type V8 = Succ V7
type V9 = Succ V8

type ANY  = TypVar V0
type ANY1 = TypVar V1
type ANY2 = TypVar V2
type ANY3 = TypVar V3
type ANY4 = TypVar V4
type ANY5 = TypVar V5
type ANY6 = TypVar V6
type ANY7 = TypVar V7
type ANY8 = TypVar V8
type ANY9 = TypVar V9

--------------------------------------------------------------------------------
-- Operations on type reps                                                    --
--------------------------------------------------------------------------------

-- | If 'isInstanceOf' fails it returns a type error
type TypeError = String

-- | @t1 `isInstanceOf` t2@ checks if @t1@ is an instance of @t2@
isInstanceOf :: TypeRep -> TypeRep -> Either TypeError ()
isInstanceOf t1 t2 = void (unify (skolemize t1) t2)

-- | @funResultTy t1 t2@ is the type of the result when applying a function
-- of type @t1@ to an argument of type @t2@
funResultTy :: TypeRep -> TypeRep -> Either TypeError TypeRep
funResultTy t1 t2 = do
  let anyTy = mkTypVar $ typeOf (undefined :: V0)
  s <- unify (alphaRename "f" t1) $ mkTyConApp tcFun [alphaRename "x" t2, anyTy]
  return $ normalize $ subst s anyTy

--------------------------------------------------------------------------------
-- Alpha-renaming and normalization                                           --
--------------------------------------------------------------------------------

alphaRename :: String -> TypeRep -> TypeRep
alphaRename prefix (isTypVar -> Just x) =
  mkTypVar (mkTyConApp (mkTyCon prefix) [x])
alphaRename prefix (splitTyConApp -> (c, ts)) =
  mkTyConApp c (map (alphaRename prefix) ts)

tvars :: TypeRep -> [Var]
tvars (isTypVar -> Just x)       = [x]
tvars (splitTyConApp -> (_, ts)) = concatMap tvars ts

normalize :: TypeRep -> TypeRep
normalize t = subst (zip (tvars t) anys) t
  where
    anys :: [TypeRep]
    anys = map mkTypVar (iterate succ zero)

    succ :: TypeRep -> TypeRep
    succ = mkTyConApp succTyCon . (:[])

    zero :: TypeRep
    zero = mkTyConApp zeroTyCon []

mkTyCon :: String -> TyCon
mkTyCon = mkTyCon3 "rank1typeable" "Data.Rank1Typeable"

succTyCon :: TyCon
succTyCon = let (c, _) = splitTyConApp (typeOf (undefined :: Succ Zero)) in c

zeroTyCon :: TyCon
zeroTyCon = let (c, _) = splitTyConApp (typeOf (undefined :: Zero)) in c

--------------------------------------------------------------------------------
-- Unification                                                                --
--------------------------------------------------------------------------------

type Substitution = [(Var, TypeRep)]
type Equation     = (TypeRep, TypeRep)
type Var          = TypeRep

skolemize :: TypeRep -> TypeRep
skolemize (isTypVar -> Just x)       = mkTyConApp skolem [x]
skolemize (splitTyConApp -> (c, ts)) = mkTyConApp c (map skolemize ts)

occurs :: Var -> TypeRep -> Bool
occurs x (isTypVar -> Just x')      = x == x'
occurs x (splitTyConApp -> (_, ts)) = any (occurs x) ts

subst :: Substitution -> TypeRep -> TypeRep
subst s (isTypVar -> Just x)       = fromMaybe (mkTypVar x) (lookup x s)
subst s (splitTyConApp -> (c, ts)) = mkTyConApp c (map (subst s) ts)

unify :: TypeRep
      -> TypeRep
      -> Either TypeError Substitution
unify = \t1 t2 -> go [] [(t1, t2)]
  where
    go :: Substitution
       -> [Equation]
       -> Either TypeError Substitution
    go acc [] =
      return acc
    go acc ((t1, t2) : eqs) | t1 == t2 = -- Note: equality check is fast
      go acc eqs
    go acc ((isTypVar -> Just x, t) : eqs) =
      if x `occurs` t
        then Left "Occurs check"
        else go ((x, t) : map (second $ subst [(x, t)]) acc)
                (map (subst [(x, t)] *** subst [(x, t)]) eqs)
    go acc ((t, isTypVar -> Just x) : eqs) =
      go acc ((mkTypVar x, t) : eqs)
    go acc ((splitTyConApp -> (c1, ts1), splitTyConApp -> (c2, ts2)) : eqs) =
      if c1 /= c2
        then Left $ "Cannot unify " ++ show c1 ++ " and " ++ show c2
        else go acc (zip ts1 ts2 ++ eqs)

--------------------------------------------------------------------------------
-- Pretty-printing                                                            --
--------------------------------------------------------------------------------

instance Show TyCon where
  showsPrec _ c = showString (tyConName c)

instance Show TypeRep where
  showsPrec p (splitTyConApp -> (tycon, tys)) =
      case tys of
        [] -> showsPrec p tycon
        [anyIdx -> Just i] | tycon == typVar -> showString "ANY" . showIdx i
        [x] | tycon == tcList ->
          showChar '[' . shows x . showChar ']'
        [a,r] | tycon == tcFun ->
          showParen (p > 8) $ showsPrec 9 a
                            . showString " -> "
                            . showsPrec 8 r
        xs | isTupleTyCon tycon ->
          showTuple xs
        _ ->
          showParen (p > 9) $ showsPrec p tycon
                            . showChar ' '
                            . showArgs tys
    where
      showIdx 0 = showString ""
      showIdx i = shows i

showArgs :: Show a => [a] -> ShowS
showArgs [] = id
showArgs [a] = showsPrec 10 a
showArgs (a:as) = showsPrec 10 a . showString " " . showArgs as

anyIdx :: TypeRep -> Maybe Int
anyIdx (splitTyConApp -> (c, []))  | c == zeroTyCon = Just 0
anyIdx (splitTyConApp -> (c, [t])) | c == succTyCon = (+1) <$> anyIdx t
anyIdx _ = Nothing

showTuple :: [TypeRep] -> ShowS
showTuple args = showChar '('
               . foldr (.) id ( intersperse (showChar ',')
                              $ map (showsPrec 10) args
                              )
               . showChar ')'

isTupleTyCon :: TyCon -> Bool
isTupleTyCon = isPrefixOf "(," . tyConName
