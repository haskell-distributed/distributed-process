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
    -- * Eliminating static values 
  , RemoteTable
  , initRemoteTable
  , registerStatic
  , unstatic 
    -- * Closures
  , Closure(Closure)
  , unclosure 
  , staticClosure
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
  , Typeable
  , Dynamic
  , toDynamic
  ) where

import Prelude hiding (const, fst, snd)
import qualified Prelude (const, fst, snd)
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
import qualified Control.Arrow as Arrow ((***), app)
import Data.Rank1Dynamic (Dynamic, toDynamic, fromDynamic, dynApply)
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

--------------------------------------------------------------------------------
-- Eliminating static values                                                  --
--------------------------------------------------------------------------------

-- | Runtime dictionary for 'unstatic' lookups 
newtype RemoteTable = RemoteTable (Map String Dynamic)

-- | Initial remote table
initRemoteTable :: RemoteTable
initRemoteTable = 
      registerStatic "$compose"       (toDynamic compose)
    . registerStatic "$const"         (toDynamic const)
    . registerStatic "$split"         (toDynamic split)
    . registerStatic "$app"           (toDynamic app)
    . registerStatic "$decodeEnvPair" (toDynamic decodeEnvPair)
    $ RemoteTable Map.empty
  where
    compose :: (ANY2 -> ANY3) -> (ANY1 -> ANY2) -> ANY1 -> ANY3
    compose = (.)
 
    const :: ANY1 -> ANY2 -> ANY1
    const = Prelude.const

    split :: (ANY1 -> ANY3) -> (ANY2 -> ANY4) -> (ANY1, ANY2) -> (ANY3, ANY4)
    split = (Arrow.***)

    app :: (ANY1 -> ANY2, ANY1) -> ANY2
    app = Arrow.app

    decodeEnvPair :: ByteString -> (ByteString, ByteString)
    decodeEnvPair = decode

-- | Register a static label
registerStatic :: String -> Dynamic -> RemoteTable -> RemoteTable
registerStatic label dyn (RemoteTable rtable)
  = RemoteTable (Map.insert label dyn rtable)

-- Pseudo-type: RemoteTable -> Static a -> a
resolveStaticLabel :: RemoteTable -> StaticLabel -> Either String Dynamic
resolveStaticLabel (RemoteTable rtable) (StaticLabel label) = 
    case Map.lookup label rtable of
      Nothing -> Left $ "Invalid static label '" ++ label ++ "'"
      Just d  -> Right d
resolveStaticLabel rtable (StaticApply label1 label2) = do
    f <- resolveStaticLabel rtable label1 
    x <- resolveStaticLabel rtable label2
    f `dynApply` x
resolveStaticLabel rtable (StaticDuplicate label) = do
    x <- resolveStaticLabel rtable label -- Resolve only to get type info 
    toDynamic mkStatic `dynApply` x
  where
    mkStatic :: ANY -> Static ANY
    mkStatic _ = Static label

unstatic :: Typeable a => RemoteTable -> Static a -> Either String a
unstatic rtable (Static static) = do 
  dyn <- resolveStaticLabel rtable static 
  fromDynamic dyn

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
unclosure :: Typeable a => RemoteTable -> Closure a -> Either String a
unclosure rtable (Closure static env) = do 
  f <- unstatic rtable static
  return (f env)

-- | Convert a static value into a closure.
staticClosure :: forall a. Typeable a => Static a -> Closure a
staticClosure static = Closure (staticConst static) empty

--------------------------------------------------------------------------------
-- Predefined static values                                                   --
--------------------------------------------------------------------------------

-- | Static version of ('Prelude..')
composeStatic :: (Typeable a, Typeable b, Typeable c) 
              => Static ((b -> c) -> (a -> b) -> a -> c)
composeStatic = staticLabel "$compose" 

-- | Static version of 'const'
constStatic :: (Typeable a, Typeable b)
            => Static (a -> b -> a)
constStatic = staticLabel "$const"           

-- | Static version of ('Arrow.***')
splitStatic :: (Typeable a, Typeable a', Typeable b, Typeable b') 
            => Static ((a -> b) -> (a' -> b') -> (a, a') -> (b, b')) 
splitStatic = staticLabel "$split"

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
