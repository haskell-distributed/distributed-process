-- | /Towards Haskell in the Cloud/ introduces a new typing construct called 
-- @static@. Unfortunately, ghc does not yet include support for @static@. In
-- this module we provide a workaround, which at the same time also extends
-- the functionality of @static@ as described in the paper and makes it more
-- expressive.
-- 
-- The main idea (already discussed in /Towards Haskell in the Cloud/, section
-- /Faking It/) is to maintain a runtime mapping from labels (strings) to
-- values. A basic static value (introduced using 'staticLabel') then is an
-- index into this runtime mapping. It is the responsibility of the client code
-- to make sure that the corresponding value in the 'RemoteTable' matches the
-- type of the label, although we do runtime type checks where possible. For
-- this reason, we only work with 'Typeable' values in this module. 
module Control.Distributed.Static 
  ( -- * Introducing static values
    Static
  , staticLabel
  , staticApply
  , staticDuplicate
--  , staticTypeOf
    -- * Eliminating static values 
  , RemoteTable
  , initRemoteTable
  , registerStatic
  , unstatic 
    -- * Closures
  , Closure(Closure)
  , unclosure 
  , staticClosure
    -- * Static values
  , idStatic 
  , composeStatic
  , constStatic 
  , flipStatic
  , fstStatic
  , sndStatic
  , firstStatic
  , secondStatic
  , splitStatic
  , unitStatic
  , appStatic
    -- * Combinators on static values
  , staticCompose
  , staticSplit
  , staticConst
    -- * Combinators on closures
  , closureApplyStatic
  , closureApply
  , closureCompose
  , closureSplit
    -- * Re-exports 
  , Dynamic
  , toDynamic
  , fromDynamic
  , dynTypeRep
  ) where

import Prelude hiding (id, (.), const, flip, fst, snd)
import qualified Prelude (const, flip, fst, snd)
import Data.Binary 
  ( Binary(get, put)
  , Put
  , Get
  , putWord8
  , getWord8
  , encode
  , decode
  )
import Data.ByteString.Lazy (ByteString, empty)
import Data.Map (Map)
import qualified Data.Map as Map (lookup, empty, insert)
import Control.Applicative ((<$>), (<*>))
import Control.Category (Category(id, (.)))
import qualified Control.Arrow as Arrow (first, second, (***), app)
import Data.Rank1Dynamic (Dynamic, toDynamic, fromDynamic, dynApply, dynTypeRep)
import Data.Rank1Typeable 
  ( Typeable
  , typeOf
  , ANY
  , ANY1
  , ANY2
  , ANY3
  , ANY4
  , isInstanceOf
  )

--------------------------------------------------------------------------------
-- Introducing static values                                                  --
--------------------------------------------------------------------------------

data StaticLabel =
    StaticLabel String
  | StaticApply StaticLabel StaticLabel
  | StaticDuplicate StaticLabel
  deriving (Typeable, Show)

-- | A static value. Static is opaque; see 'staticLabel', 'staticApply',
-- 'staticDuplicate' or 'staticTypeOf'.
newtype Static a = Static StaticLabel 
  deriving (Typeable, Show)

instance Typeable a => Binary (Static a) where
  put (Static label) = putStaticLabel label >> put (typeOf (undefined :: a))
  get = do
    label   <- getStaticLabel
    typeRep <- get
    case typeOf (undefined :: a) `isInstanceOf` typeRep of
      Left err -> fail $ "Static.get: type error: " ++ err
      Right () -> return (Static label)

-- We don't want StaticLabel to be its own Binary instance
putStaticLabel :: StaticLabel -> Put
putStaticLabel (StaticLabel string) = 
  putWord8 0 >> put string 
putStaticLabel (StaticApply label1 label2) = 
  putWord8 1 >> putStaticLabel label1 >> putStaticLabel label2
putStaticLabel (StaticDuplicate label) = 
  putWord8 2 >> putStaticLabel label

getStaticLabel :: Get StaticLabel
getStaticLabel = do
  header <- getWord8
  case header of
    0 -> StaticLabel <$> get
    1 -> StaticApply <$> getStaticLabel <*> getStaticLabel
    2 -> StaticDuplicate <$> getStaticLabel
    _ -> fail "StaticLabel.get: invalid" 
 
-- | Create a primitive static value.
-- 
-- It is the responsibility of the client code to make sure the corresponding
-- entry in the 'RemoteTable' has the appropriate type.
staticLabel :: forall a. String -> Static a
staticLabel = Static . StaticLabel 

-- | Apply two static values
staticApply :: Static (a -> b) -> Static a -> Static b
staticApply (Static f) (Static x) = Static (StaticApply f x)

-- | Co-monadic 'duplicate' for static values
staticDuplicate :: forall a. Static a -> Static (Static a)
staticDuplicate (Static x) = Static (StaticDuplicate x) 

{-
-- | @staticTypeOf (x :: a)@ mimicks @static (undefined :: a)@ -- even if
-- @x@ is not static, the type of @x@ always is.
staticTypeOf :: forall a. Typeable a => a -> Static a 
staticTypeOf _ = Static (StaticLabel "$undefined" (typeOf (undefined :: a)))

typeOfStaticLabel :: StaticLabel -> TypeRep
typeOfStaticLabel = undefined
{-
typeOfStaticLabel (StaticLabel _ typ) 
  = typ 
typeOfStaticLabel (StaticApply f x) 
  = fromJust $ funResultTy (typeOfStaticLabel f) (typeOfStaticLabel x)
typeOfStaticLabel (StaticDuplicate _ typ)
  = typ
-}
-}

--------------------------------------------------------------------------------
-- Eliminating static values                                                  --
--------------------------------------------------------------------------------

-- | Runtime dictionary for 'unstatic' lookups 
newtype RemoteTable = RemoteTable (Map String Dynamic)

-- | Initial remote table
initRemoteTable :: RemoteTable
initRemoteTable = 
      registerStatic "$id"            (toDynamic identity)
    . registerStatic "$compose"       (toDynamic compose)
    . registerStatic "$const"         (toDynamic const)
    . registerStatic "$flip"          (toDynamic flip)
    . registerStatic "$fst"           (toDynamic fst)
    . registerStatic "$snd"           (toDynamic snd)
    . registerStatic "$first"         (toDynamic first)
    . registerStatic "$second"        (toDynamic second)
    . registerStatic "$split"         (toDynamic split)
    . registerStatic "$unit"          (toDynamic ())
    . registerStatic "$app"           (toDynamic app)
    . registerStatic "$decodeEnvPair" (toDynamic decodeEnvPair)
    $ RemoteTable Map.empty
  where
    identity :: ANY -> ANY
    identity = id

    compose :: (ANY2 -> ANY3) -> (ANY1 -> ANY2) -> ANY1 -> ANY3
    compose = (.)
 
    const :: ANY1 -> ANY2 -> ANY1
    const = Prelude.const

    flip :: (ANY1 -> ANY2 -> ANY3) -> ANY2 -> ANY1 -> ANY3
    flip = Prelude.flip

    fst :: (ANY1, ANY2) -> ANY1
    fst = Prelude.fst

    snd :: (ANY1, ANY2) -> ANY2
    snd = Prelude.snd

    first :: (ANY1 -> ANY2) -> (ANY1, ANY3) -> (ANY2, ANY3)
    first = Arrow.first

    second :: (ANY1 -> ANY2) -> (ANY3, ANY1) -> (ANY3, ANY2)
    second = Arrow.second

    split :: (ANY1 -> ANY3) -> (ANY2 -> ANY4) -> (ANY1, ANY2) -> (ANY3, ANY4)
    split = (Arrow.***)

    decodeEnvPair :: ByteString -> (ByteString, ByteString)
    decodeEnvPair = decode

    app :: (ANY1 -> ANY2, ANY1) -> ANY2
    app = Arrow.app

-- | Register a static label
registerStatic :: String -> Dynamic -> RemoteTable -> RemoteTable
registerStatic label dyn (RemoteTable rtable)
  = RemoteTable (Map.insert label dyn rtable)

-- Pseudo-type: RemoteTable -> Static a -> a
resolveStaticLabel :: RemoteTable -> StaticLabel -> Maybe Dynamic
resolveStaticLabel (RemoteTable rtable) (StaticLabel label) = 
    Map.lookup label rtable
resolveStaticLabel rtable (StaticApply label1 label2) = do
    f <- resolveStaticLabel rtable label1 
    x <- resolveStaticLabel rtable label2
    case f `dynApply` x of
      Left _err -> Nothing
      Right y   -> Just y
resolveStaticLabel rtable (StaticDuplicate label) = do
    x <- resolveStaticLabel rtable label -- Resolve only to get type info 
    case toDynamic mkStatic `dynApply` x of
      Left _err -> Nothing
      Right y   -> Just y
  where
    mkStatic :: ANY -> Static ANY
    mkStatic _ = Static label

unstatic :: Typeable a => RemoteTable -> Static a -> Maybe a
unstatic rtable (Static static) = 
  case resolveStaticLabel rtable static of
    Nothing  -> Nothing
    Just dyn -> case fromDynamic dyn of
      Left _err -> Nothing
      Right x   -> Just x

--------------------------------------------------------------------------------
-- Closures                                                                   -- 
--------------------------------------------------------------------------------

-- | A closure is a static value and an encoded environment
data Closure a = Closure (Static (ByteString -> a)) ByteString
  deriving (Typeable, Show)

instance Typeable a => Binary (Closure a) where
  put (Closure static env) = put static >> put env
  get = Closure <$> get <*> get 

-- | Resolve a closure
unclosure :: Typeable a => RemoteTable -> Closure a -> Maybe a
unclosure rtable (Closure static env) = do 
  f <- unstatic rtable static
  return (f env)

-- | Convert a static value into a closure.
staticClosure :: forall a. Typeable a => Static a -> Closure a
staticClosure static = Closure (staticConst static) empty

--------------------------------------------------------------------------------
-- Predefined static values                                                   --
--------------------------------------------------------------------------------

-- | Static version of 'id'
idStatic :: (Typeable a) 
         => Static (a -> a)
idStatic = staticLabel "$id" 

-- | Static version of ('Prelude..')
composeStatic :: (Typeable a, Typeable b, Typeable c) 
              => Static ((b -> c) -> (a -> b) -> a -> c)
composeStatic = staticLabel "$compose" 

-- | Static version of 'const'
constStatic :: (Typeable a, Typeable b)
            => Static (a -> b -> a)
constStatic = staticLabel "$const"           

-- | Static version of 'flip'
flipStatic :: (Typeable a, Typeable b, Typeable c)
           => Static ((a -> b -> c) -> b -> a -> c)
flipStatic = staticLabel "$flip"

-- | Static version of 'fst'
fstStatic :: (Typeable a, Typeable b)
          => Static ((a, b) -> a)
fstStatic = staticLabel "$fst"

-- | Static version of 'snd'
sndStatic :: (Typeable a, Typeable b)
          => Static ((a, b) -> b)
sndStatic = staticLabel "$snd"          

-- | Static version of 'Arrow.first'
firstStatic :: (Typeable a, Typeable b, Typeable c)
            => Static ((a -> b) -> (a, c) -> (b, c))
firstStatic = staticLabel "$first" 

-- | Static version of 'Arrow.second'
secondStatic :: (Typeable a, Typeable b, Typeable c)
             => Static ((a -> b) -> (c, a) -> (c, b))
secondStatic = staticLabel "$second" 

-- | Static version of ('Arrow.***')
splitStatic :: (Typeable a, Typeable a', Typeable b, Typeable b') 
            => Static ((a -> b) -> (a' -> b') -> (a, a') -> (b, b')) 
splitStatic = staticLabel "$split"

-- | Static version of @()@
unitStatic :: Static ()
unitStatic = staticLabel "$unit"

-- | Static version of 'Arrow.app'
appStatic :: (Typeable a, Typeable b)
          => Static ((a -> b, a) -> b)
appStatic = staticLabel "$app"

--------------------------------------------------------------------------------
-- Combinators on static values                                               --
--------------------------------------------------------------------------------

staticCompose :: (Typeable a, Typeable b, Typeable c)
              => Static (b -> c) -> Static (a -> b) -> Static (a -> c)
staticCompose g f = composeStatic `staticApply` g `staticApply` f

staticSplit :: (Typeable a, Typeable a', Typeable b, Typeable b') 
            => Static (a -> b) -> Static (a' -> b') -> Static ((a, a') -> (b, b'))
staticSplit f g = splitStatic `staticApply` f `staticApply` g

staticConst :: (Typeable a, Typeable b)
            => Static a -> Static (b -> a)
staticConst x = constStatic `staticApply` x 

--------------------------------------------------------------------------------
-- Combinators on Closures                                                    --
--------------------------------------------------------------------------------

closureApplyStatic :: forall a b. (Typeable a, Typeable b)
                   => Static (a -> b) -> Closure a -> Closure b
closureApplyStatic f (Closure decoder env) = 
  Closure (f `staticCompose` decoder) env

decodeEnvPairStatic :: Static (ByteString -> (ByteString, ByteString))
decodeEnvPairStatic = staticLabel "$decodeEnvPair"

closureApply :: forall a b. (Typeable a, Typeable b)
             => Closure (a -> b) -> Closure a -> Closure b
closureApply (Closure fdec fenv) (Closure xdec xenv) = 
    Closure decoder (encode (fenv, xenv))
  where
    decoder :: Static (ByteString -> b)
    decoder = appStatic 
            `staticCompose`
              (fdec `staticSplit` xdec)
            `staticCompose`
              decodeEnvPairStatic 

closureCompose :: (Typeable a, Typeable b, Typeable c)
               => Closure (b -> c) -> Closure (a -> b) -> Closure (a -> c)
closureCompose g f = composeStatic `closureApplyStatic` g `closureApply` f

closureSplit :: (Typeable a, Typeable a', Typeable b, Typeable b') 
             => Closure (a -> b) -> Closure (a' -> b') -> Closure ((a, a') -> (b, b'))
closureSplit f g = splitStatic `closureApplyStatic` f `closureApply` g 
