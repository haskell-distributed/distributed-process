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
  , staticTypeOf
    -- * Eliminating static values 
  , RemoteTable
  , initRemoteTable
  , registerStatic
  , resolveStatic 
    -- * Closures
  , Closure(Closure)
  , staticClosure
  , resolveClosure
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
  , toDyn
  , unsafeToDyn
  , fromDyn
  , fromDynamic
  , dynTypeRep
  ) where

import Prelude hiding (id, (.))
import Data.Typeable 
  ( Typeable
  , TypeRep
  , typeOf
  , funResultTy
  )
import Data.Maybe (fromJust)
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
import Control.Distributed.Static.Internal.Dynamic 
  ( Dynamic
  , dynApply
  , toDyn
  , unsafeToDyn
  , fromDyn
  , dynTypeRep
  , fromDynamic
  , unsafeCastDyn
  )
import Control.Distributed.Static.Internal.TypeRep (compareTypeRep)

--------------------------------------------------------------------------------
-- Introducing static values                                                  --
--------------------------------------------------------------------------------

data StaticLabel =
    StaticLabel String TypeRep
  | StaticApply StaticLabel StaticLabel
  | StaticDuplicate StaticLabel TypeRep
  deriving (Typeable, Show)

-- | A static value. Static is opaque; see 'staticLabel', 'staticApply',
-- 'staticDuplicate' or 'staticTypeOf'.
newtype Static a = Static StaticLabel 
  deriving (Typeable, Show)

instance Typeable a => Binary (Static a) where
  put (Static label) = putStaticLabel label
  get = do
    label <- getStaticLabel
    if typeOfStaticLabel label `compareTypeRep` typeOf (undefined :: a)
      then return $ Static label 
      else fail "Static.get: type error"

-- We don't want StaticLabel to be its own Binary instance
putStaticLabel :: StaticLabel -> Put
putStaticLabel (StaticLabel string typ) = 
  putWord8 0 >> put string >> put typ 
putStaticLabel (StaticApply label1 label2) = 
  putWord8 1 >> putStaticLabel label1 >> putStaticLabel label2
putStaticLabel (StaticDuplicate label typ) = 
  putWord8 2 >> putStaticLabel label >> put typ

getStaticLabel :: Get StaticLabel
getStaticLabel = do
  header <- getWord8
  case header of
    0 -> StaticLabel <$> get <*> get
    1 -> StaticApply <$> getStaticLabel <*> getStaticLabel
    2 -> StaticDuplicate <$> getStaticLabel <*> get
    _ -> fail "StaticLabel.get: invalid" 

-- | Create a primitive static value.
-- 
-- It is the responsibility of the client code to make sure the corresponding
-- entry in the 'RemoteTable' has the appropriate type.
staticLabel :: forall a. Typeable a => String -> Static a
staticLabel label = Static (StaticLabel label (typeOf (undefined :: a)))

-- | Apply two static values
staticApply :: Static (a -> b) -> Static a -> Static b
staticApply (Static f) (Static x) = Static (StaticApply f x)

-- | Co-monadic 'duplicate' for static values
staticDuplicate :: forall a. Typeable a => Static a -> Static (Static a)
staticDuplicate (Static x) = 
  Static (StaticDuplicate x (typeOf (undefined :: Static a)))

-- | @staticTypeOf (x :: a)@ mimicks @static (undefined :: a)@ -- even if
-- @x@ is not static, the type of @x@ always is.
staticTypeOf :: forall a. Typeable a => a -> Static a 
staticTypeOf _ = Static (StaticLabel "$undefined" (typeOf (undefined :: a)))

typeOfStaticLabel :: StaticLabel -> TypeRep
typeOfStaticLabel (StaticLabel _ typ) 
  = typ 
typeOfStaticLabel (StaticApply f x) 
  = fromJust $ funResultTy (typeOfStaticLabel f) (typeOfStaticLabel x)
typeOfStaticLabel (StaticDuplicate _ typ)
  = typ

--------------------------------------------------------------------------------
-- Eliminating static values                                                  --
--------------------------------------------------------------------------------

-- | Runtime dictionary for 'unstatic' lookups 
newtype RemoteTable = RemoteTable (Map String Dynamic)

-- | Initial remote table
initRemoteTable :: RemoteTable
initRemoteTable = 
      registerStatic "$id"            (unsafeToDyn identity)
    . registerStatic "$compose"       (unsafeToDyn compose)
    . registerStatic "$const"         (unsafeToDyn const)
    . registerStatic "$flip"          (unsafeToDyn flip)
    . registerStatic "$fst"           (unsafeToDyn fst)
    . registerStatic "$snd"           (unsafeToDyn snd)
    . registerStatic "$first"         (unsafeToDyn first)
    . registerStatic "$second"        (unsafeToDyn second)
    . registerStatic "$split"         (unsafeToDyn split)
    . registerStatic "$unit"          (toDyn ())
    . registerStatic "$app"           (unsafeToDyn app)
    . registerStatic "$decodeEnvPair" (toDyn decodeEnvPair)
    $ RemoteTable Map.empty
  where
    identity :: a -> a
    identity = id

    compose :: (b -> c) -> (a -> b) -> a -> c
    compose = (.)

    first :: (a -> b) -> (a, c) -> (b, c)
    first = Arrow.first

    second :: (a -> b) -> (c, a) -> (c, b)
    second = Arrow.second

    split :: (a -> b) -> (a' -> b') -> (a, a') -> (b, b')
    split = (Arrow.***)

    decodeEnvPair :: ByteString -> (ByteString, ByteString)
    decodeEnvPair = decode

    app :: (a -> b, a) -> b
    app = Arrow.app

-- | Register a static label
registerStatic :: String -> Dynamic -> RemoteTable -> RemoteTable
registerStatic label dyn (RemoteTable rtable)
  = RemoteTable (Map.insert label dyn rtable)

-- | Resolve a Static value.
resolveStatic :: RemoteTable -> Static a -> Maybe Dynamic
resolveStatic (RemoteTable rtable) (Static (StaticLabel string typ)) = do
  unsafeCastDyn (const typ) <$> Map.lookup string rtable 
resolveStatic rtable (Static (StaticApply static1 static2)) = do
  f <- resolveStatic rtable (Static static1)
  x <- resolveStatic rtable (Static static2)
  f `dynApply` x
resolveStatic _rtable (Static (StaticDuplicate static typ)) = 
  return . unsafeCastDyn (const typ) $ unsafeToDyn (Static static)

--------------------------------------------------------------------------------
-- Closures                                                                   -- 
--------------------------------------------------------------------------------

-- | A closure is a static value and an encoded environment
data Closure a = Closure (Static (ByteString -> a)) ByteString
  deriving (Typeable, Show)

instance Typeable a => Binary (Closure a) where
  put (Closure static env) = put static >> put env
  get = Closure <$> get <*> get 

-- | Convert a static value into a closure.
staticClosure :: forall a. Typeable a => Static a -> Closure a
staticClosure static = Closure (staticConst static) empty

-- | Resolve a Closure
resolveClosure :: RemoteTable -> Static a -> ByteString -> Maybe Dynamic
resolveClosure rtable static env = do
  decoder <- resolveStatic rtable static
  decoder `dynApply` toDyn env

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
