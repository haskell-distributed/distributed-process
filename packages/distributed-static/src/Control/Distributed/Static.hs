-- | /Towards Haskell in the Cloud/ (Epstein et al, Haskell Symposium 2011)
-- introduces the concept of /static/ values: values that are known at compile
-- time. In a distributed setting where all nodes are running the same
-- executable, static values can be serialized simply by transmitting a code
-- pointer to the value. GHC supports this through 'StaticPtr' (the @static@
-- form, enabled by the @StaticPointers@ extension). In this module we build
-- closures on top of it.
--
-- [Closures]
--
-- Closures in functional programming arise when we partially apply a function.
-- A closure is a code pointer together with a runtime data structure that
-- represents the value of the free variables of the function. A 'Closure'
-- represents these closures explicitly so that they can be serialized:
--
-- > data Closure a = Closure (StaticPtr (ByteString -> a)) ByteString
--
-- See /Towards Haskell in the Cloud/ for the rationale behind representing
-- the function closure environment in serialized ('ByteString') form. For
-- example:
--
-- > addClosure :: Int -> Closure (Int -> Int)
-- > addClosure x = closure (static add) (encode x)
-- >
-- > add :: ByteString -> Int -> Int
-- > add bs y = decode bs + y
--
-- Any static value can trivially be used as a 'Closure': see 'Closure'.
-- Closures can also be combined ('closureApplyStatic', 'closureApply',
-- 'closureCompose', 'closureSplit'). Since a 'StaticPtr' can only be created
-- by a @static@ form at compile time, combining closures does not create new
-- pointers: the result remembers the closures that it was built from, and
-- these are serialized together with it.
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StaticPointers #-}
{-# LANGUAGE RoleAnnotations #-}
module Control.Distributed.Static
  ( -- * Closures
    Closure
  , closure
  , unclosure
    -- * Derived closure combinators
  , closureApplyStatic
  , closureApply
  , closureCompose
  , closureSplit
  ) where

import Data.Binary
  ( Binary(get, put)
  , Get
  , Put
  , encode
  , getWord8
  , putWord8
  )
import Data.ByteString.Lazy (ByteString)
import Control.Arrow ((***))
import Control.DeepSeq (NFData(rnf))
import qualified GHC.Exts as GHC (Any)
import GHC.Fingerprint.Type (Fingerprint(..))
import GHC.StaticPtr
import Data.Typeable (Typeable)
import Control.Monad.IO.Class (MonadIO (liftIO))

-- | A closure is a code pointer together with an encoded environment, or an
-- application of closures
--
-- Code pointers are stored as 'StaticKey's, and only looked up when the closure
-- is resolved ('unclosure'). This way, decoding a closure with an unknown key
-- does not fail: the error is raised when the closure is resolved instead,
-- which allows the receiver of a bad closure to handle it as a failure of the
-- process that runs it.
--
-- Closures are created with 'closure', by combining other closures, or from
-- @static@ forms: 'Closure' is an instance of 'IsStatic', so that
--
-- > static f :: Closure a
--
-- is a closure with an empty environment, for any @f :: a@ (there is no
-- separate function to convert a static value into a closure). To convert an
-- existing 'StaticPtr', use 'fromStaticPtr'.
--
-- @since 0.4.0
data Closure a where
  Pointer :: !StaticKey -> Closure a
  Decoder :: !StaticKey -> !ByteString -> Closure a
  Apply :: Closure (b -> a) -> Closure b -> Closure a

-- | A @static@ form can be used as a 'Closure'
--
-- @since 0.4.0
instance IsStatic Closure where
  fromStaticPtr = staticClosure

type role Closure nominal

instance Eq (Closure a) where
  c1 == c2 = encode c1 == encode c2

instance Ord (Closure a) where
  c1 `compare` c2 = encode c1 `compare` encode c2

instance Show (Closure a) where
  show (Pointer key) = concat ["<<static ", show key, ">>"]
  show (Decoder key env) = concat ["<<closure ", show key, " ", show env, ">>"]
  show (Apply f x) = concat ["<<apply ", show f, " ", show x, ">>"]

instance NFData (Closure a) where
  rnf (Pointer _) = ()
  rnf (Decoder _ env) = rnf env
  rnf (Apply f x) = rnf f `seq` rnf x

instance Binary (Closure a) where
  put (Pointer key) = putWord8 0 >> putKey key
  put (Decoder key env) = putWord8 1 >> putKey key >> put env
  put (Apply f x) = putWord8 2 >> put f >> put x
  get = do
    tag <- getWord8
    case tag of
      0 -> Pointer <$> getKey
      1 -> Decoder <$> getKey <*> get
      2 -> getApply
      _ -> fail "Closure.get: invalid"

getApply :: forall a. Get (Closure a)
getApply = Apply <$> (get :: Get (Closure (GHC.Any -> a)))
                 <*> (get :: Get (Closure GHC.Any))

putKey :: StaticKey -> Put
putKey (Fingerprint hi lo) = put hi >> put lo

getKey :: Get StaticKey
getKey = Fingerprint <$> get <*> get

closure :: StaticPtr (ByteString -> a) -- ^ Decoder
        -> ByteString                  -- ^ Encoded closure environment
        -> Closure a
closure = Decoder . staticKey
-- Do not inline the functions which take a 'StaticPtr': GHC then creates a new
-- binding for the pointer, which is not the one that the static pointer table
-- knows about, and fails to link ("symbol not found" at startup).
{-# NOINLINE closure #-}

-- | Resolve a closure
--
-- Fails if the closure refers to a static pointer which does not exist in this
-- executable, which happens if the closure was decoded from a message that was
-- sent by a different binary.
--
-- @since 0.4.0
unclosure :: (MonadIO m, MonadFail m) => Closure a -> m a
unclosure c = do
  result <- liftIO (resolve c)
  case result of
    Left err -> fail ("Could not resolve closure: " ++ err)
    Right x  -> return x

resolve :: Closure a -> IO (Either String a)
resolve (Pointer key) = fmap deRefStaticPtr <$> lookupStaticPtr key
resolve (Decoder key env) = fmap (`deRefStaticPtr` env) <$> lookupStaticPtr key
resolve (Apply f x) = do
  resolvedF <- resolve f
  resolvedX <- resolve x
  return (resolvedF <*> resolvedX)

lookupStaticPtr :: StaticKey -> IO (Either String (StaticPtr a))
lookupStaticPtr key =
  maybe (Left "invalid static pointer") Right <$> unsafeLookupStaticPtr key

--------------------------------------------------------------------------------
-- Combinators on closures                                                    --
--------------------------------------------------------------------------------

staticClosure :: StaticPtr a -> Closure a
staticClosure = Pointer . staticKey
{-# NOINLINE staticClosure #-}

-- | Apply a static function to a closure
closureApplyStatic :: StaticPtr (a -> b) -> Closure a -> Closure b
closureApplyStatic f = closureApply (staticClosure f)
{-# NOINLINE closureApplyStatic #-}

-- | Closure application
closureApply :: Closure (a -> b) -> Closure a -> Closure b
closureApply = Apply

-- | Closure composition
closureCompose :: (Typeable a, Typeable b, Typeable c)
               => Closure (b -> c) -> Closure (a -> b) -> Closure (a -> c)
closureCompose g f = closureApplyStatic (static (.)) g `closureApply` f

-- | Closure version of ('Control.Arrow.***')
closureSplit :: (Typeable a, Typeable b, Typeable a', Typeable b')
             => Closure (a -> b) -> Closure (a' -> b') -> Closure ((a, a') -> (b, b'))
closureSplit f g = closureApplyStatic (static (***)) f `closureApply` g
